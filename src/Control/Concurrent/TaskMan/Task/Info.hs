{-# LANGUAGE RecordWildCards, TemplateHaskell #-}

module Control.Concurrent.TaskMan.Task.Info where

import Data.Time (UTCTime)
import Data.Either (isRight)

type TaskId = Int

-- Properties that are set once when the task is started and never change.
data Initial = Initial
  { _initialTaskId :: TaskId
  , _initialTitle :: String
  , _initialStarted :: UTCTime
  } deriving (Show)

-- Properties that change while the task is running
data Progress = Progress
  { _currentPhase :: String
  , _progressTotalWork :: Int
  , _progressDoneWork :: Int
  } deriving (Show)

data Status
  = Done
  | Canceled
  | Failure String
  deriving (Show)

data Final = Final
  { _finalTime :: UTCTime
  , _finalStatus :: Status
  , _finalTotalWork :: Int
  } deriving (Show)

type Current = Either Progress Final

data Info = Info
  { _infoInitial :: Initial
  , _infoCurrent :: Current
  } deriving (Show)

isFinished :: Current -> Bool
isFinished = isRight

