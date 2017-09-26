{-# LANGUAGE RecordWildCards #-}

module Control.Concurrent.TaskMan.Task.Info where

import Data.Time

type TaskId = Int

data Status
  = InProgress
  | Pause
  | Waiting
  | Canceling
  | Failure
  | Canceled
  | Killed
  | Done
  deriving (Show, Eq)

finalStatuses :: [Status]
finalStatuses = [Done, Killed, Canceled, Failure]

-- Properties that are set once when the task is started and never change.
data Initial = Initial
  { initialTaskId :: TaskId
  , initialTitle :: String
  , initialStarted :: UTCTime
  , initialParent :: Maybe TaskId
  } deriving (Show)

-- Properties that change while the task is running
data Current = Current
  { currentStatus :: Status
  , currentPhase :: String
  , currentEnded :: Maybe UTCTime
  , currentChildren :: [Info]
  , currentTotalWork :: Maybe Int
  , currentDoneWork :: Int
  } deriving (Show)

data Info = Info
  { infoInitial :: Initial
  , infoCurrent :: Current
  } deriving (Show)

isFinalStatus :: Status -> Bool
isFinalStatus s = s `elem` finalStatuses

percentDone :: Current -> Maybe Float
percentDone Current{..} =
  if currentStatus == Done
     then Just 100.0
     else fmap (((fromIntegral currentDoneWork) /) . fromIntegral) currentTotalWork
