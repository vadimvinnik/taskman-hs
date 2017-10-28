module Control.Concurrent.TaskMan.Task.Info
  ( TaskId
  , Initial(..)
  , Progress(..)
  , Status(..)
  , Final(..)
  , Current
  , Info(..)
  , InfoMap
  , isFinished
  ) where

import Data.Time (UTCTime)
import Data.Either (isRight)
import Data.Map (Map)

type TaskId = Int

-- Properties that are set once when the task is started and never change later
data Initial = Initial
  { _taskId :: TaskId
  , _title :: String
  , _started :: UTCTime
  } deriving (Show)

-- Properties that change while the task is running
data Progress = Progress
  { _phase :: String
  , _totalWork :: Int
  , _doneWork :: Int
  } deriving (Show)

-- Properties that are set when the task finishes and never change later
data Status
  = Done
  | Canceled
  | Failure String
  deriving (Show)

data Final = Final
  { _ended :: UTCTime
  , _status :: Status
  , _work :: Int
  } deriving (Show)

-- Either the current progress if the task is running or the final result
type Current = Either Progress Final

-- Full info about the task
data Info = Info
  { _initial :: Initial
  , _current :: Current
  } deriving (Show)

type InfoMap = Map TaskId Info

isFinished :: Current -> Bool
isFinished = isRight

