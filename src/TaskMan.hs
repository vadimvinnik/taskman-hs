module TaskMan where

import Control.Concurrent
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
  -- Global control
  | Shutdown

data Task = Task
  { thread :: ThreadId
  , initial :: InitialInfo
  }

type TaskMap = M.Map TaskId Task

data TaskMan = TaskMan
  { nextId :: MVar TaskId
  , taskMap :: MVar TaskMap
  , eventM :: MVar Event
  , mainThread :: ThreadId
  }

start :: IO TaskMan
start = do
  nextId_ <- newMVar 0
  taskMap_ <- newMVar M.empty
  eventM_ <- newEmptyMVar
  let worker = do
      event <- takeMVar eventM_
      case event of
        Start action idM -> do
          taskId <- modifyMVar nextId_ (\x -> return (x+1, x))
          threadId <- forkIO action
          now <- getCurrentTime
          let initial = InitialInfo {
            taskId = taskId,
            title = "Task #" ++ show taskId,
            started = now,
            parent = Nothing
          }
          let task = Task threadId initial
          modifyMVar taskMap_ (\m -> return (M.insert taskId task m, ()))
          putMVar idM taskId
          worker
        Shutdown -> return ()
  mainThread_ <- forkIO $ worker
  return $ TaskMan nextId_ taskMap_ eventM_ mainThread_
