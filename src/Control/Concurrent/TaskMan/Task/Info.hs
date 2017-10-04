{-# LANGUAGE RecordWildCards, TemplateHaskell #-}

module Control.Concurrent.TaskMan.Task.Info where

import Data.Time (UTCTime)
import Data.Either (isRight)
import Control.Lens

type TaskId = Int

-- Properties that are set once when the task is started and never change.
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

type Current = Either Progress Final

data Info = Info
  { _initial :: Initial
  , _current :: Current
  } deriving (Show)

makeLenses ''Initial
makeLenses ''Progress
makeLenses ''Final
makeLenses ''Info

isFinished :: Current -> Bool
isFinished = isRight

