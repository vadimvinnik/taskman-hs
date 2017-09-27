{-# LANGUAGE TupleSections,
             ScopedTypeVariables,
             TemplateHaskell
 #-}

module Control.Concurrent.TaskMan where

import Control.Concurrent
import Data.Map ((!))
import qualified Data.Map as M
import Data.Time
import Control.Concurrent.TaskMan.Task.Info
import Control.Exception
import Control.Lens

type Action = IO ()

data Event
  = ControlStart Action (MVar TaskId)
  | ControlCancel TaskId
  | ControlShutdown
  | GetTotalCount (MVar Int)
  | GetStatusCount Status (MVar Int)
  | GetInfo TaskId (MVar (Maybe Info))
  | GetAllInfos (MVar [Info])
  | GetFilteredInfos (Info -> Bool) (MVar [Info])
  | ReportDone TaskId
  | ReportCanceled TaskId
  | ReportFailure TaskId String
  | ReportPhase TaskId String

data Task = Task
  { _taskThreadId :: ThreadId
  , _taskInfo :: Info
  }

type TaskMap = M.Map TaskId Task

data TaskManState = TaskManState
  { _taskManStateNextId :: TaskId
  , _taskManStateTaskMap :: TaskMap
  }

makeLenses ''Task
makeLenses ''TaskManState

newtype TaskMan = TaskMan { taskManEventM :: MVar Event }

newTaskMan :: IO TaskMan
newTaskMan = do
  stateM <- newMVar $ TaskManState 0 M.empty
  eventM <- newEmptyMVar
  _ <- forkIO $ taskManLoop stateM eventM
  return $ TaskMan eventM

start :: TaskMan -> Action -> IO TaskId
start taskMan action = sendEventAndGetResult taskMan (ControlStart action)

cancel :: TaskMan -> TaskId -> IO ()
cancel (TaskMan eventM) taskId = putMVar eventM $ ControlCancel taskId

shutdown :: TaskMan -> IO ()
shutdown (TaskMan eventM) = putMVar eventM $ ControlShutdown

getTotalCount :: TaskMan -> IO Int
getTotalCount taskMan = sendEventAndGetResult taskMan GetTotalCount

getStatusCount :: TaskMan -> Status -> IO Int
getStatusCount taskMan status = sendEventAndGetResult taskMan (GetStatusCount status)

getInfo :: TaskMan -> TaskId -> IO (Maybe Info)
getInfo taskMan taskId = sendEventAndGetResult taskMan (GetInfo taskId)

getAllInfos :: TaskMan -> IO [Info]
getAllInfos taskMan = sendEventAndGetResult taskMan GetAllInfos

getFilteredInfos :: TaskMan -> (Info -> Bool) -> IO [Info]
getFilteredInfos taskMan p = sendEventAndGetResult taskMan (GetFilteredInfos p)

sendEventAndGetResult :: TaskMan -> (MVar a -> Event) -> IO a
sendEventAndGetResult (TaskMan eventM) f = do
  resultM <- newEmptyMVar
  putMVar eventM $ f resultM
  takeMVar resultM

taskManLoop :: MVar TaskManState -> MVar Event -> IO ()
taskManLoop stateM eventM = do
  event <- takeMVar eventM
  case event of
    ControlStart action taskIdM  -> onStart action eventM stateM taskIdM
    ControlCancel taskId         -> onCancel taskId stateM
    GetTotalCount countM         -> onGetTotalCount stateM countM
    GetStatusCount status countM -> onGetCount status stateM countM
    GetInfo taskId infoM         -> onGetInfo taskId stateM infoM
    GetAllInfos infosM           -> onGetAllInfos stateM infosM
    GetFilteredInfos p infosM    -> onGetFilteredInfos p stateM infosM
    ReportDone taskId            -> onDone taskId stateM
    ReportCanceled taskId        -> onCanceled taskId stateM
    ReportFailure taskId msg     -> onFailure taskId msg stateM
    _-> return () -- tmp. until all events are implemented
  case event of
    ControlShutdown -> return ()
    _ -> taskManLoop stateM eventM

getModifyingTaskManState :: (TaskManState -> IO (TaskManState, a)) -> MVar TaskManState -> IO a
getModifyingTaskManState f stateM = do
  state <- takeMVar stateM
  (state', result) <- f state
  putMVar stateM state'
  return result

putModifyingTaskManState :: (TaskManState -> IO (TaskManState, a)) -> MVar TaskManState -> MVar a -> IO ()
putModifyingTaskManState f stateM resultM = do
  result <- getModifyingTaskManState f stateM
  putMVar resultM result

modifyTaskManState :: (TaskManState -> IO TaskManState) -> MVar TaskManState -> IO ()
modifyTaskManState f = getModifyingTaskManState (fmap (fmap (, ())) f)

queryState :: (TaskManState -> a) -> MVar TaskManState -> MVar a -> IO ()
queryState f stateM mVar = (readMVar stateM) >>= (putMVar mVar) . f

onStart :: Action -> MVar Event -> MVar TaskManState -> MVar TaskId -> IO ()
onStart action eventM stateM taskIdM =
  putModifyingTaskManState (startTaskAndGetId action eventM) stateM taskIdM

startTaskAndGetId :: Action -> MVar Event -> TaskManState -> IO (TaskManState, TaskId)
startTaskAndGetId action eventM state = do
  let taskId = state^.taskManStateNextId
  now <- getCurrentTime
  threadId <- forkIO $ wrapTask action taskId eventM
  let initial = Initial {
    _initialTaskId = taskId,
    _initialTitle = "Task #" ++ show taskId,
    _initialStarted = now,
    _initialParent = Nothing
  }
  let current = Current {
    _currentStatus = InProgress,
    _currentPhase = "",
    _currentEnded = Nothing,
    _currentChildren = [],
    _currentTotalWork = Nothing,
    _currentDoneWork = 0
  }
  let task = Task threadId (Info initial current)
  let state' = state
        & taskManStateNextId +~ 1
        & taskManStateTaskMap %~ (M.insert taskId task)
  return (state', taskId)

-- todo: does it really catch ThreadKilled?
wrapTask :: Action -> TaskId -> MVar Event -> IO ()
wrapTask action taskId eventM =
  catches (action >> signalDone) (map Handler [handleCanceled, handleFailure]) where
    signalDone = signal ReportDone
    handleCanceled e = if e == ThreadKilled then signal ReportCanceled else throw e
    handleFailure e = signal $ (flip ReportFailure) (displayException e)
    signal event = putMVar eventM $ event taskId

onCancel :: TaskId -> MVar TaskManState -> IO ()
onCancel taskId stateM = do
  taskManState <- readMVar stateM
  let task = (taskManState^.taskManStateTaskMap) ! taskId
  killThread $ task^.taskThreadId

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

onDone :: TaskId -> MVar TaskManState -> IO ()
onDone taskId stateM = modifyTaskManState (setFinalStatus taskId Done "Done") stateM

onCanceled :: TaskId -> MVar TaskManState -> IO ()
onCanceled taskId stateM = modifyTaskManState (setFinalStatus taskId Canceled "Canceled") stateM

onFailure :: TaskId -> String -> MVar TaskManState -> IO ()
onFailure taskId msg stateM = modifyTaskManState (setFinalStatus taskId Canceled msg) stateM

setFinalStatus :: TaskId -> Status -> String -> TaskManState -> IO TaskManState
setFinalStatus taskId status msg state = do
  now <- getCurrentTime
  let updateCurrent current = current
        & currentStatus .~ status
        & currentPhase .~ msg
        & currentEnded .~ Just now
  let updateTask task = task & taskInfo.infoCurrent %~ updateCurrent
  return $ state & taskManStateTaskMap %~ M.update (Just . updateTask) taskId

