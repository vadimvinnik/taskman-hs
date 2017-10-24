{-# LANGUAGE RecordWildCards, TemplateHaskell #-}

module Control.Concurrent.TaskMan.Task.Info where

import Data.Time (UTCTime)
import Data.Either (isRight)

type TaskId = Int

-- Properties that are set once when the task is started and never change.
data Initial = Initial
  { taskId :: TaskId
  , title :: String
  , started :: UTCTime
  } deriving (Show)

-- Properties that change while the task is running
data Progress = Progress
  { phase :: String
  , totalWork :: Int
  , doneWork :: Int
  } deriving (Show)

data Status
  = Done
  | Canceled
  | Failure String
  deriving (Show)

data Final = Final
  { ended :: UTCTime
  , status :: Status
  , work :: Int
  } deriving (Show)

type Current = Either Progress Final

data Info = Info
  { initial :: Initial
  , current :: Current
  } deriving (Show)

isFinished :: Current -> Bool
isFinished = isRight

