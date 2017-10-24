{-# LANGUAGE TupleSections,
             ScopedTypeVariables,
             TemplateHaskell
 #-}

module Control.Concurrent.TaskMan
  ( TaskMan
  , newTaskMan
  , start
  , shutdown
  ) where

import qualified Control.Concurrent.TaskMan.Task as T
import qualified Control.Concurrent.TaskMan.Task.Info as I

import Control.Concurrent
import Control.Concurrent.STM
import Data.Map ((!))
import qualified Data.Map as M
import Control.Monad.Reader (runReaderT)
import Data.Time (getCurrentTime)
import Control.Exception

data Event
  = Start T.Task String (MVar I.TaskId)
  | Query (MVar TaskManState)
  | Finish I.TaskId I.Status
  | Shutdown

data TaskDescriptor = TaskDescriptor
  { threadId :: ThreadId
  , params :: T.TaskParams
  }

type ActiveTaskMap = M.Map I.TaskId TaskDescriptor
type FinishedTaskMap = M.Map I.TaskId I.Final

data TaskManState = TaskManState
  { nextId :: I.TaskId
  , active :: ActiveTaskMap
  , finished :: FinishedTaskMap
  }

newtype TaskMan = TaskMan { eventM :: MVar Event }

-- Exports

newTaskMan :: IO TaskMan
newTaskMan = do
  stateM <- newMVar $ TaskManState 0 M.empty M.empty
  eventM <- newEmptyMVar
  _ <- forkIO $ taskManLoop stateM eventM
  return $ TaskMan eventM

start :: TaskMan -> T.Task -> String -> IO I.TaskId
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

onStart :: T.Task -> String -> MVar Event -> MVar TaskManState -> MVar I.TaskId -> IO ()
onStart action title eventM stateM taskIdM =
  putModifyingTaskManState (startTaskAndGetId action title eventM) stateM taskIdM

onQuery :: MVar TaskManState -> MVar TaskManState -> IO ()
onQuery stateM resultM = (readMVar stateM) >>= (putMVar resultM)

onFinish :: I.TaskId -> I.Status -> MVar TaskManState -> IO ()
onFinish taskId status stateM = modifyTaskManState (setTasktStatus taskId status) stateM

setTasktStatus :: I.TaskId -> I.Status -> TaskManState -> IO TaskManState
setTasktStatus taskId status state = do
  now <- getCurrentTime
  let descriptor = (active state) ! taskId
  let currentV = T.currentV $ params descriptor
  (Left progress) <- readTVarIO currentV
  let final = I.Final {
    I.ended = now,
    I.status = status,
    I.work = I.doneWork progress
  }
  atomically $ writeTVar currentV $ Right final
  let active' = M.delete taskId $ active state
  let finished' = M.insert taskId final $ finished state
  let state' = state {
    active = active',
    finished = finished'
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

startTaskAndGetId :: T.Task -> String -> MVar Event -> TaskManState -> IO (TaskManState, I.TaskId)
startTaskAndGetId task title eventM state = do
  let taskId = nextId state
  now <- getCurrentTime
  let initial = I.Initial {
    I.taskId = taskId,
    I.title = if null title then "Task #" ++ show taskId else title,
    I.started = now
  }
  let progress = I.Progress {
    I.phase = "In progress",
    I.totalWork = 0,
    I.doneWork = 0
  }
  currentV <- newTVarIO $ Left progress
  let params = T.TaskParams {
    T.initial = initial,
    T.currentV = currentV
  }
  threadId <- forkIO $ runTask task params eventM
  let descriptor = TaskDescriptor threadId params
  let state' = state {
    nextId = taskId + 1,
    active = M.insert taskId descriptor (active state)
  }
  return (state', taskId)

runTask :: T.Task -> T.TaskParams -> MVar Event -> IO ()
runTask task params eventM =
  catches ((runReaderT task params) >> signalDone) (map Handler [handleCanceled, handleFailure]) where
    signalDone = signal I.Done
    handleCanceled e = if e == ThreadKilled then signal I.Canceled else throw e
    handleFailure e = signal $ I.Failure (displayException e)
    signal status = putMVar eventM $ Finish taskId status
    taskId = I.taskId $ T.initial $ params

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
