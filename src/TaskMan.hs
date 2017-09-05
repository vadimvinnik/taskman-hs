{-# LANGUAGE TupleSections #-}

module TaskMan where

import Control.Concurrent
import Control.Monad
import Data.Map ((!))
import qualified Data.Map as M
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
  , info :: Info
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
    Start action idM -> modifyState (onStart action idM) stateM >>= putMVar idM
    Kill taskId -> modifyState_ (onKill taskId) stateM
    GetTotalCount countM -> queryState (onGetTotalCount) stateM countM
    GetCount state countM -> queryState (onGetCount state) stateM countM
    GetInfo taskId infoM -> queryState (onGetInfo taskId) stateM infoM
    _ -> undefined
  case event of
    Shutdown -> return ()
    _ -> taskManLoop stateM eventM

queryState :: (TaskManState -> a) -> MVar TaskManState -> MVar a -> IO ()
queryState f stateM mVar = (readMVar stateM) >>= (putMVar mVar) . f

modifyState :: (TaskManState -> IO (TaskManState, a)) -> MVar TaskManState -> IO a
modifyState f stateM = do
  state <- takeMVar stateM
  (state', result) <- f state
  putMVar stateM state'
  return result

modifyState_ :: (TaskManState -> IO TaskManState) -> MVar TaskManState -> IO ()
modifyState_ f = modifyState (fmap (fmap (, ())) f)

onStart :: IO () -> MVar TaskId -> TaskManState -> IO (TaskManState, TaskId)
onStart action idM state = do
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
  let info = Info initial current
  let task = Task threadId info
  let taskMap' = M.insert taskId task $ taskMap state
  return (TaskManState (taskId + 1) taskMap', taskId)

onKill :: TaskId -> TaskManState -> IO TaskManState
onKill taskId state = do
  let taskMap_ = taskMap state
  let task_ = taskMap_ ! taskId
  let info_ = info task_
  let current_ = current info_
  let current' = current_ { state = Canceling }
  let info' = info_ { current = current' }
  let task' = task_ { info = info' }
  let taskMap' = M.insert taskId task' taskMap_
  let state' = state { taskMap = taskMap' }
  killThread $ threadId task_
  return state'

onGetTotalCount :: TaskManState -> Int
onGetTotalCount
  = M.size
  . taskMap

onGetCount :: State -> TaskManState -> Int
onGetCount s
  = length
  . filter (==s)
  . fmap (state . current . info . snd)
  . M.toList
  . taskMap

onGetInfo :: TaskId -> TaskManState -> Info
onGetInfo id
  = info
  . (!id)
  . taskMap
