{-# LANGUAGE     TupleSections                  #-}
{-# LANGUAGE     ScopedTypeVariables            #-}
{-# LANGUAGE     DisambiguateRecordFields       #-}
{-# LANGUAGE     DuplicateRecordFields          #-}

module Control.Concurrent.TaskMan
  ( TaskMan
  , newTaskMan
  , start
  , shutdown
  ) where

import Control.Concurrent.TaskMan.Task as T
import Control.Concurrent.TaskMan.Task.Info

import Control.Concurrent
import Control.Concurrent.STM
import Data.Map ((!))
import qualified Data.Map as M
import Control.Monad.Reader (runReaderT)
import Data.Time (getCurrentTime)
import Control.Exception

data Event
  = Start Task String (MVar TaskId)
  | Query (MVar TaskManState)
  | Finish TaskId Status
  | Shutdown

data TaskDescriptor = TaskDescriptor
  { _threadId :: ThreadId
  , _params :: TaskParams
  }

type ActiveTaskMap = M.Map TaskId TaskDescriptor
type FinishedTaskMap = M.Map TaskId Final

data TaskManState = TaskManState
  { _nextId :: TaskId
  , _active :: ActiveTaskMap
  , _finished :: FinishedTaskMap
  }

newtype TaskMan = TaskMan { _eventM :: MVar Event }

-- Exports

newTaskMan :: IO TaskMan
newTaskMan = do
  stateM <- newMVar $ TaskManState 0 M.empty M.empty
  eventM <- newEmptyMVar
  _ <- forkIO $ taskManLoop stateM eventM
  return $ TaskMan eventM

start :: TaskMan -> Task -> String -> IO TaskId
start taskMan task title = sendEventAndGetResult taskMan (Start task title)

query :: TaskMan -> IO TaskManState
query taskMan = sendEventAndGetResult taskMan Query

shutdown :: TaskMan -> IO ()
shutdown (TaskMan eventM) = putMVar eventM $ Shutdown

-- Internals

taskManLoop :: MVar TaskManState -> MVar Event -> IO ()
taskManLoop stateM eventM = do
  event <- takeMVar eventM
  case event of
    Start task title taskIdM  -> onStart task title eventM stateM taskIdM
    Query resultM             -> onQuery stateM resultM
    Finish taskId status      -> onFinish taskId status stateM
    Shutdown                  -> return ()
  case event of
    Shutdown -> return ()
    _ -> taskManLoop stateM eventM

sendEventAndGetResult :: TaskMan -> (MVar a -> Event) -> IO a
sendEventAndGetResult (TaskMan eventM) f = do
  resultM <- newEmptyMVar
  putMVar eventM $ f resultM
  takeMVar resultM

onStart :: Task -> String -> MVar Event -> MVar TaskManState -> MVar TaskId -> IO ()
onStart action title eventM stateM taskIdM =
  putModifyingTaskManState (startTaskAndGetId action title eventM) stateM taskIdM

onQuery :: MVar TaskManState -> MVar TaskManState -> IO ()
onQuery stateM resultM = (readMVar stateM) >>= (putMVar resultM)

onFinish :: TaskId -> Status -> MVar TaskManState -> IO ()
onFinish taskId status stateM = modifyTaskManState (setTasktStatus taskId status) stateM

setTasktStatus :: TaskId -> Status -> TaskManState -> IO TaskManState
setTasktStatus taskId status state = do
  now <- getCurrentTime
  let descriptor = (_active state) ! taskId
  let currentV = _currentV $ _params descriptor
  (Left progress) <- readTVarIO currentV
  let final = Final {
    _ended = now,
    _status = status,
    _work = _doneWork progress
  }
  atomically $ writeTVar currentV $ Right final
  let active' = M.delete taskId $ _active state
  let finished' = M.insert taskId final $ _finished state
  let state' = state {
    _active = active',
    _finished = finished'
  }
  return state'

putModifyingTaskManState :: (TaskManState -> IO (TaskManState, a)) -> MVar TaskManState -> MVar a -> IO ()
putModifyingTaskManState f stateM resultM = do
  result <- getModifyingTaskManState f stateM
  putMVar resultM result

getModifyingTaskManState :: (TaskManState -> IO (TaskManState, a)) -> MVar TaskManState -> IO a
getModifyingTaskManState f stateM = do
  state <- takeMVar stateM
  (state', result) <- f state
  putMVar stateM state'
  return result

modifyTaskManState :: (TaskManState -> IO TaskManState) -> MVar TaskManState -> IO ()
modifyTaskManState f = getModifyingTaskManState (fmap (fmap (, ())) f)

startTaskAndGetId :: Task -> String -> MVar Event -> TaskManState -> IO (TaskManState, TaskId)
startTaskAndGetId task title eventM state = do
  let taskId = _nextId state
  now <- getCurrentTime
  let initial = Initial {
    _taskId = taskId,
    _title = if null title then "Task #" ++ show taskId else title,
    _started = now
  }
  let progress = Progress {
    _phase = "In progress",
    _totalWork = 0,
    _doneWork = 0
  }
  currentV <- newTVarIO $ Left progress
  let params = TaskParams {
    _initial = initial,
    _currentV = currentV
  }
  threadId <- forkIO $ runTask task params eventM
  let descriptor = TaskDescriptor threadId params
  let state' = state {
    _nextId = taskId + 1,
    _active = M.insert taskId descriptor (_active state)
  }
  return (state', taskId)

runTask :: Task -> TaskParams -> MVar Event -> IO ()
runTask task params eventM =
  catches ((runReaderT task params) >> signalDone) (map Handler [handleCanceled, handleFailure]) where
    signalDone = signal Done
    handleCanceled e = if e == ThreadKilled then signal Canceled else throw e
    handleFailure e = signal $ Failure (displayException e)
    signal status = putMVar eventM $ Finish taskId status
    taskId = _taskId $ T._initial $ params

{-
onGetTotalCount :: MVar TaskManState -> MVar Int -> IO ()
onGetTotalCount stateM countM = queryState worker stateM countM where
  worker
    = M.size
    . view taskManStateTaskMap

onGetCount :: Status -> MVar TaskManState -> MVar Int -> IO ()
onGetCount s stateM countM = queryState worker stateM countM where
  worker = length . (getFilteredInfosFromTaskManState $ (s==) . (view $ infoCurrent.currentStatus))

onGetInfo :: TaskId -> MVar TaskManState -> MVar (Maybe Info) -> IO ()
onGetInfo taskId stateM infoM = queryState worker stateM infoM where
  worker
    = fmap (view taskInfo)
    . M.lookup taskId
    . view taskManStateTaskMap

onGetAllInfos :: MVar TaskManState -> MVar [Info] -> IO ()
onGetAllInfos stateM infosM = queryState (getFilteredInfosFromTaskManState $ const True) stateM infosM

onGetFilteredInfos :: (Info -> Bool) -> MVar TaskManState -> MVar [Info] -> IO ()
onGetFilteredInfos p stateM infosM = queryState (getFilteredInfosFromTaskManState p) stateM infosM

getFilteredInfosFromTaskManState :: (Info -> Bool) -> TaskManState -> [Info]
getFilteredInfosFromTaskManState p
  = filter p
  . fmap ((view taskInfo) . snd)
  . M.toList
  . view taskManStateTaskMap
-}
