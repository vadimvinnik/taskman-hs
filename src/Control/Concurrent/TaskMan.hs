{-# LANGUAGE     TupleSections                  #-}
{-# LANGUAGE     DuplicateRecordFields          #-}
{-# LANGUAGE     RecordWildCards                #-}

module Control.Concurrent.TaskMan
  ( TaskDescriptor
  , TaskManState(_active, _finished)
  , TaskMan
  , newTaskMan
  , start
  , query
  , cancel
  , getInfo
  ) where

import Control.Concurrent.TaskMan.Task as T
import Control.Concurrent.TaskMan.Task.Info as I

import Control.Concurrent
import Control.Concurrent.STM
import Data.Either.Combinators (fromLeft')
import Data.Map (Map, empty, insert, delete, (!))
import Control.Monad.Reader (runReaderT)
import Data.Time (getCurrentTime)
import Control.Exception (AsyncException(..), Handler(..), catches, throw, displayException)

data TaskDescriptor = TaskDescriptor
  { _threadId :: ThreadId
  , _params :: TaskParams
  }

type ActiveTaskMap = Map TaskId TaskDescriptor
type FinishedTaskMap = Map TaskId Info

data TaskManState = TaskManState
  { _nextId :: TaskId
  , _active :: ActiveTaskMap
  , _finished :: FinishedTaskMap
  }

newtype TaskMan = TaskMan { _stateM :: MVar TaskManState }

-- Exports

newTaskMan :: IO TaskMan
newTaskMan = fmap TaskMan (newMVar $ TaskManState 0 empty empty)

start :: TaskMan -> Task -> String -> IO TaskDescriptor
start taskMan action title = do
  let stateM = _stateM taskMan
  state <- takeMVar stateM
  let taskId = _nextId state
  now <- getCurrentTime
  let initial = Initial
        { _taskId = taskId
        , _title = if null title then "Task #" ++ show taskId else title
        , _started = now
        }
  let progress = Progress
        { _phase = "In progress"
        , _totalWork = 0
        , _doneWork = 0
        }
  currentV <- newTVarIO $ Left progress
  let params = TaskParams
        { _initial = initial
        , _currentV = currentV
        }
  threadId <- forkIO $ runTask action params stateM
  let descriptor = TaskDescriptor threadId params
  let state' = state
        { _nextId = taskId + 1
        , _active = insert taskId descriptor (_active state)
        }
  putMVar stateM state'
  return descriptor

query :: TaskMan -> IO TaskManState
query = readMVar . _stateM

cancel :: TaskDescriptor -> IO ()
cancel (TaskDescriptor{..}) = throwTo _threadId ThreadKilled

getInfo :: TaskDescriptor -> IO Info
getInfo task = do
  let TaskParams initial currentV = _params task
  current <- readTVarIO currentV
  return $ Info initial current

-- Internals

runTask :: Task -> TaskParams -> MVar TaskManState -> IO ()
runTask action params stateM =
  catches ((runReaderT action params) >> onDone) (map Handler [onCanceled, onFailure]) where
    onDone = signal Done
    onCanceled e = if e == ThreadKilled then signal Canceled else throw e
    onFailure e = signal $ Failure (displayException e)
    signal status = onFinish taskId status stateM
    taskId = _taskId $ T._initial $ params

onFinish :: TaskId -> Status -> MVar TaskManState -> IO ()
onFinish taskId status stateM = do
  state <- takeMVar stateM
  now <- getCurrentTime
  let descriptor = (_active state) ! taskId
  let params = _params descriptor
  let currentV = _currentV params
  current <- readTVarIO currentV
  let progress = fromLeft' current
  let final = Final
        { _ended = now
        , _status = status
        , _work = _doneWork progress
        }
  let current' = Right final
  atomically $ writeTVar currentV current'
  let active' = delete taskId $ _active state
  let initial = T._initial params
  let finished' = insert taskId (Info initial current') $ _finished state
  let state' = state
        { _active = active'
        , _finished = finished'
        }
  putMVar stateM state'

