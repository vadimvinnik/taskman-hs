{-# LANGUAGE TupleSections #-}

module Control.Concurrent.TaskMan where

import Control.Concurrent
import Data.Map ((!))
import qualified Data.Map as M
import Data.Time
import Control.Concurrent.TaskMan.Task.Info

type Action = IO ()

data Event
  = ControlStart Action (MVar TaskId)
  | ControlCancel TaskId
  | ControlKill TaskId
  | ControlShutdown
  | GetTotalCount (MVar Int)
  | GetCount Status (MVar Int)
  | GetInfo TaskId (MVar (Maybe Info))
  | ReportStatus TaskId Status
  | ReportPhase TaskId String

data Task = Task
  { taskThreadId :: ThreadId
  , taskInfo :: Info
  }

type TaskMap = M.Map TaskId Task

data TaskManState = TaskManState
  { taskManStateNextId :: TaskId
  , taskManStateTaskMap :: TaskMap
  }

newtype TaskMan = TaskMan { taskManEventM :: MVar Event }

newTaskMan :: IO TaskMan
newTaskMan = do
  stateM <- newMVar $ TaskManState 0 M.empty
  eventM <- newEmptyMVar
  _ <- forkIO $ taskManLoop stateM eventM
  return $ TaskMan eventM

taskManLoop :: MVar TaskManState -> MVar Event -> IO ()
taskManLoop stateM eventM = do
  event <- takeMVar eventM
  case event of
    ControlStart action taskIdM  -> putModifyingTaskManState (startTaskAndGetId action) stateM taskIdM
    ControlKill taskId           -> onKill taskId stateM
    GetTotalCount countM  -> queryState getTotalCountHelper stateM countM
    GetCount state countM -> queryState (getCountHelper state) stateM countM
    GetInfo taskId infoM  -> queryState (getInfoHelper taskId) stateM infoM
    _              -> return () -- tmp. until all events are implemented
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

onStart action stateM taskIdM = putModifyingTaskManState (startTaskAndGetId action) stateM taskIdM

startTaskAndGetId :: IO () -> TaskManState -> IO (TaskManState, TaskId)
startTaskAndGetId action state = do
  let taskId = taskManStateNextId state
  now <- getCurrentTime
  threadId <- forkIO action
  let initial = Initial {
    initialTaskId = taskId,
    initialTitle = "Task #" ++ show taskId,
    initialStarted = now,
    initialParent = Nothing
  }
  let current = Current {
    currentStatus = InProgress,
    currentPhase = "",
    currentEnded = Nothing,
    currentChildren = [],
    currentTotalWork = Nothing,
    currentDoneWork = 0
  }
  let info = Info initial current
  let task = Task threadId info
  let taskMap' = M.insert taskId task $ taskManStateTaskMap state
  return (TaskManState (taskId + 1) taskMap', taskId)

onKill taskId stateM = do
  taskManState <- readMVar stateM
  let task = (taskManStateTaskMap taskManState) ! taskId
  killThread $ taskThreadId task

getTotalCountHelper :: TaskManState -> Int
getTotalCountHelper
  = M.size
  . taskManStateTaskMap

getCountHelper :: Status -> TaskManState -> Int
getCountHelper s
  = length
  . filter (==s)
  . fmap (currentStatus . infoCurrent . taskInfo . snd)
  . M.toList
  . taskManStateTaskMap

getInfoHelper :: TaskId -> TaskManState -> Maybe Info
getInfoHelper taskId
  = fmap taskInfo
  . M.lookup taskId
  . taskManStateTaskMap
