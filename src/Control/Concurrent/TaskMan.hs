{-# LANGUAGE     TupleSections                  #-}
{-# LANGUAGE     DuplicateRecordFields          #-}
{-# LANGUAGE     RecordWildCards                #-}

module Control.Concurrent.TaskMan
  ( Action
  , Task
  , TaskManState(_active, _finished)
  , TaskMan
  , TaskMap
  , askId
  , setPhase
  , setTotalWork
  , setDoneWork
  , newTaskMan
  , start
  , getActiveTasks
  , getFinishedInfos
  , getAllInfos
  , cancel
  , getInfo
  ) where

import Control.Concurrent.TaskMan.Task.Info as I hiding (_initial)

import Control.Concurrent
import Control.Concurrent.STM
import Data.Either.Combinators (fromLeft')
import Data.Map (Map, empty, insert, delete, union, (!))
import Data.Traversable (sequence)
import Control.Monad.Reader
import Data.Time (getCurrentTime)
import Control.Exception (AsyncException(..), Handler(..), catches, throw, displayException)

data Params = Params
  { _initial :: Initial
  , _currentV :: TVar Current
  }

type ActionTo a = ReaderT Params IO a
type Action = ActionTo ()

data Task = Task
  { _threadId :: ThreadId
  , _params :: Params
  }

type TaskMap = Map TaskId Task

data TaskManState = TaskManState
  { _nextId :: TaskId
  , _active :: TaskMap
  , _finished :: InfoMap
  }

newtype TaskMan = TaskMan { _stateM :: MVar TaskManState }

-- Exports

askId :: ActionTo TaskId
askId = asks (_taskId . (_initial :: Params -> Initial))

setPhase :: String -> ActionTo ()
setPhase s = modifyProgress (\p -> p { _phase = s })

setTotalWork :: Int -> ActionTo ()
setTotalWork x = modifyProgress (\p -> p { _totalWork = x})

setDoneWork :: Int -> ActionTo ()
setDoneWork x = modifyProgress (\p -> p { _doneWork = x})

newTaskMan :: IO TaskMan
newTaskMan = fmap TaskMan (newMVar $ TaskManState 0 empty empty)

start :: TaskMan -> Action -> String -> IO Task
start taskMan action title = do
  let stateM = _stateM taskMan
  state <- takeMVar stateM
  let taskId = _nextId state
  now <- getCurrentTime
  let initial = Initial
        { _taskId = taskId
        , _title = if null title then "Action #" ++ show taskId else title
        , _started = now
        }
  let progress = Progress
        { _phase = "In progress"
        , _totalWork = 0
        , _doneWork = 0
        }
  currentV <- newTVarIO $ Left progress
  let params = Params
        { _initial = initial
        , _currentV = currentV
        }
  threadId <- forkIO $ runTask action params stateM
  let descriptor = Task threadId params
  let state' = state
        { _nextId = taskId + 1
        , _active = insert taskId descriptor (_active state)
        }
  putMVar stateM state'
  return descriptor

getActiveTasks :: TaskMan -> IO TaskMap
getActiveTasks = fmap _active . getState

getFinishedInfos :: TaskMan -> IO InfoMap
getFinishedInfos = fmap _finished . getState

getAllInfos :: TaskMan -> IO InfoMap
getAllInfos taskMan = do
  state <- getState taskMan
  active <- atomically $ sequence $ fmap getInfoSTM $ _active state
  let finished = _finished state
  return $ union active finished

cancel :: Task -> IO ()
cancel (Task{..}) = throwTo _threadId ThreadKilled

getInfo :: Task -> IO Info
getInfo = atomically . getInfoSTM

-- Internals

askCurrentV :: ActionTo (TVar Current)
askCurrentV = asks _currentV

getState :: TaskMan -> IO TaskManState
getState = readMVar . _stateM

modifyProgress :: (Progress -> Progress) -> ActionTo ()
modifyProgress f = do
  c <- askCurrentV
  lift $ atomically $ modifyTVar' c (Left . f . fromLeft')

runTask :: Action -> Params -> MVar TaskManState -> IO ()
runTask action params stateM =
  catches ((runReaderT action params) >> onDone) (map Handler [onCanceled, onFailure]) where
    onDone = signal Done
    onCanceled e = if e == ThreadKilled then signal Canceled else throw e
    onFailure e = signal $ Failure (displayException e)
    signal status = onFinish taskId status stateM
    taskId = _taskId $ _initial $ params

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
  let initial = _initial params
  let finished' = insert taskId (Info initial current') $ _finished state
  let state' = state
        { _active = active'
        , _finished = finished'
        }
  putMVar stateM state'

getInfoSTM :: Task -> STM Info
getInfoSTM task = do
  let Params initial currentV = _params task
  current <- readTVar currentV
  return $ Info initial current

