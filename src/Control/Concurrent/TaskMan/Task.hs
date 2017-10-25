{-# LANGUAGE     DuplicateRecordFields          #-}

module Control.Concurrent.TaskMan.Task
  ( TaskOf
  , Task
  , TaskParams(..)
  , askId
  , setPhase
  , setTotalWork
  , setDoneWork
  )  where

import Control.Concurrent.TaskMan.Task.Info

import Control.Monad.Reader (ReaderT, asks, lift)
import Control.Concurrent.STM (TVar, atomically, modifyTVar')
import Data.Either.Combinators (fromLeft')

data TaskParams = TaskParams
  { _initial :: Initial
  , _currentV :: TVar Current
  }

type TaskOf a = ReaderT TaskParams IO a
type Task = TaskOf ()

askId :: TaskOf TaskId
askId = asks (_taskId . (_initial :: TaskParams -> Initial))

-- internal
askCurrentV :: TaskOf (TVar Current)
askCurrentV = asks _currentV

modifyProgress :: (Progress -> Progress) -> TaskOf ()
modifyProgress f = do
  c <- askCurrentV
  lift $ atomically $ modifyTVar' c (Left . f . fromLeft')

setPhase :: String -> TaskOf ()
setPhase s = modifyProgress (\p -> p { _phase = s })

setTotalWork :: Int -> TaskOf ()
setTotalWork x = modifyProgress (\p -> p { _totalWork = x})

setDoneWork :: Int -> TaskOf ()
setDoneWork x = modifyProgress (\p -> p { _doneWork = x})
