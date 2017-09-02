{-# LANGUAGE RecordWildCards #-}

module Info where

import Data.Time

type TaskId = Int

data State
  = Starting
  | Running
  | Paused
  | Waiting
  | Canceling
  | Failed
  | Canceled
  | Killed
  | Finished
  deriving (Show, Eq)

finals :: [State]
finals = [Finished, Failed, Canceled, Killed]

-- Properties that are set once when the task is started and never change.
data InitialInfo = InitialInfo
  { id :: TaskId
  , title :: String
  , started :: UTCTime
  , parent :: Maybe TaskId
  } deriving (Show)

-- Properties that change while the task is running
data CurrentInfo = CurrentInfo
  { state :: State
  , phase :: String
  , elapsed :: NominalDiffTime
  , children :: [Info]
  , totalWork :: Maybe Int
  , doneWork :: Int
  } deriving (Show)

data Info = Info
  { initial :: InitialInfo
  , current :: CurrentInfo
  } deriving (Show)

isFinal :: State -> Bool
isFinal s = s `elem` finals

isFinished :: Info -> Bool
isFinished = isFinal . state . current

ended :: Info -> Maybe UTCTime
ended i =
  if isFinished i
    then Just $ addUTCTime (elapsed $ current i) (started $ initial i)
    else Nothing

percentDone :: Info -> Maybe Float
percentDone i =
  fmap (\x -> (fromIntegral $ doneWork $ current i) / (fromIntegral x)) $ totalWork $ current i
