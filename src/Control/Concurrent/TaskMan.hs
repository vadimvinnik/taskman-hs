{-# LANGUAGE TupleSections #-}

module Control.Concurrent.TaskMan where

import Control.Concurrent
import Data.Map ((!))
import qualified Data.Map as M
import Data.Time
import Control.Concurrent.TaskMan.Task.Info

type Action = IO ()

data Event
  -- Controlling tasks
  = Start Action (MVar TaskId)
  | Pause TaskId
  | Resume TaskId
  | Cancel TaskId
  | Kill TaskId
  -- Queries
  | GetTotalCount (MVar Int)
  | GetCount State (MVar Int)
  | GetInfo TaskId (MVar (Maybe Info))
  -- Feedback frorm the tasks
  | Finished (TaskId)
  | Failed (TaskId)
  | Canceled (TaskId)
  -- Global control
  | Shutdown

data Task = Task
  { taskThreadId :: ThreadId
  , taskInfo :: Info
  }

type TaskMap = M.Map TaskId Task

data TaskManState = TaskManState
  { taskManStateNextId :: TaskId
  , taskManStateTaskMap :: TaskMap
  }

data TaskMan = TaskMan
  { taskManMainThread :: ThreadId
  , taskManEventM :: MVar Event
  }

newTaskMan :: IO TaskMan
newTaskMan = do
  stateM <- newMVar $ TaskManState 0 M.empty
  eventM <- newEmptyMVar
  mainThread <- forkIO $ taskManLoop stateM eventM
  return $ TaskMan mainThread eventM

taskManLoop :: MVar TaskManState -> MVar Event -> IO ()
taskManLoop stateM eventM = do
  event <- takeMVar eventM
  case event of
    Start action taskIdM -> modifyTaskManState (onStart action taskIdM) stateM >>= putMVar taskIdM
    Kill taskId -> readMVar stateM >>= onKill taskId
    GetTotalCount countM -> queryState (onGetTotalCount) stateM countM
    GetCount state countM -> queryState (onGetCount state) stateM countM
    GetInfo taskId infoM -> queryState (onGetInfo taskId) stateM infoM
    _ -> undefined
  case event of
    Shutdown -> return ()
    _ -> taskManLoop stateM eventM

queryState :: (TaskManState -> a) -> MVar TaskManState -> MVar a -> IO ()
queryState f stateM mVar = (readMVar stateM) >>= (putMVar mVar) . f

modifyTaskManState :: (TaskManState -> IO (TaskManState, a)) -> MVar TaskManState -> IO a
modifyTaskManState f stateM = do
  state <- takeMVar stateM
  (state', result) <- f state
  putMVar stateM state'
  return result

modifyTaskManState_ :: (TaskManState -> IO TaskManState) -> MVar TaskManState -> IO ()
modifyTaskManState_ f = modifyTaskManState (fmap (fmap (, ())) f)

onStart :: IO () -> MVar TaskId -> TaskManState -> IO (TaskManState, TaskId)
onStart action idM state = do
  let taskId = taskManStateNextId state
  now <- getCurrentTime
  threadId <- forkIO action
  let initial = InitialInfo {
    taskId = taskId,
    title = "Task #" ++ show taskId,
    started = now,
    parent = Nothing
  }
  let current = CurrentInfo {
    state = Running,
    phase = "",
    ended = Nothing,
    children = [],
    totalWork = Nothing,
    doneWork = 0
  }
  let info = Info initial current
  let task = Task threadId info
  let taskMap' = M.insert taskId task $ taskManStateTaskMap state
  return (TaskManState (taskId + 1) taskMap', taskId)

onKill :: TaskId -> TaskManState -> IO ()
onKill taskId taskManState =
  killThread $ taskThreadId $ (taskManStateTaskMap taskManState) ! taskId

onGetTotalCount :: TaskManState -> Int
onGetTotalCount
  = M.size
  . taskManStateTaskMap

onGetCount :: State -> TaskManState -> Int
onGetCount s
  = length
  . filter (==s)
  . fmap (state . current . taskInfo . snd)
  . M.toList
  . taskManStateTaskMap

onGetInfo :: TaskId -> TaskManState -> Maybe Info
onGetInfo taskId
  = fmap taskInfo
  . M.lookup taskId
  . taskManStateTaskMap
