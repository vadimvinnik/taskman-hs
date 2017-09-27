{-# LANGUAGE RecordWildCards, TemplateHaskell #-}

module Control.Concurrent.TaskMan.Task.Info where

import Data.Time
import Control.Lens

type TaskId = Int

data Status
  = InProgress
  | Done
  | Canceled
  | Failure
  deriving (Show, Eq, Ord)

-- Properties that are set once when the task is started and never change.
data Initial = Initial
  { _initialTaskId :: TaskId
  , _initialTitle :: String
  , _initialStarted :: UTCTime
  , _initialParent :: Maybe TaskId
  } deriving (Show)

-- Properties that change while the task is running
data Current = Current
  { _currentStatus :: Status
  , _currentPhase :: String
  , _currentEnded :: Maybe UTCTime
  , _currentChildren :: [Info]
  , _currentTotalWork :: Maybe Int
  , _currentDoneWork :: Int
  } deriving (Show)

data Info = Info
  { _infoInitial :: Initial
  , _infoCurrent :: Current
  } deriving (Show)

makeLenses ''Initial
makeLenses ''Current
makeLenses ''Info

isFinalStatus :: Status -> Bool
isFinalStatus = (>= Done)

percentDone :: Current -> Maybe Float
percentDone Current{..} =
  if _currentStatus == Done
     then Just 100.0
     else fmap (((fromIntegral _currentDoneWork) /) . fromIntegral) _currentTotalWork
