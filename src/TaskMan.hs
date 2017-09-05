module TaskMan where

import Control.Concurrent
import Control.Monad
import Data.Map as M
import Data.Time
import TaskMan.Task.Info

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
  | GetInfo TaskId (MVar Info)
  -- Feedback frorm the tasks
  | Finished (TaskId)
  | Failed (TaskId)
  | Canceled (TaskId)
  -- Global control
  | Shutdown

data Task = Task
  { threadId :: ThreadId
  , initial :: InitialInfo
  , current :: CurrentInfo
  }

type TaskMap = M.Map TaskId Task

data TaskManState = TaskManState
  { nextId ::  TaskId
  , taskMap :: TaskMap
  }

data TaskMan = TaskMan
  { mainThread :: ThreadId
  , eventM :: MVar Event
  }

newTaskMan :: IO TaskMan
newTaskMan = do
  stateM <- newMVar $ TaskManState 0 M.empty
  eventM <- newEmptyMVar
  loopThread <- forkIO $ taskManLoop stateM eventM
  return $ TaskMan loopThread eventM

taskManLoop :: MVar TaskManState -> MVar Event -> IO ()
taskManLoop stateM eventM = do
  event <- takeMVar eventM
  case event of
    Start action idM -> onStart stateM action idM
    Kill taskId -> onKill stateM taskId
    _ -> undefined
  case event of
    Shutdown -> return ()
    _ -> taskManLoop stateM eventM

onStart :: MVar TaskManState -> IO () -> MVar TaskId -> IO ()
onStart stateM action idM = do
  state <- readMVar stateM
  let taskId = nextId state
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
  let task = Task threadId initial current
  let taskMap' = M.insert taskId task $ taskMap state
  putMVar stateM $ TaskManState (taskId + 1) taskMap'
  putMVar idM taskId

onKill stateM taskId = do
  state <- readMVar stateM
  let taskState = (taskMap state) ! taskId
  killThread $ threadId taskState
