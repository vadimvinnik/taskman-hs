module Control.Concurrent.TaskMan.Task
  ( TaskOf
  , Task
  , TaskParams(..)
  , askId
  , setPhase
  , setTotalWork
  , setDoneWork
  )  where

import qualified Control.Concurrent.TaskMan.Task.Info as I

import Control.Monad.Reader (ReaderT, asks, lift)
import Control.Concurrent.STM (TVar, atomically, modifyTVar')
import Data.Either.Combinators (fromLeft')

data TaskParams = TaskParams
  { initial :: I.Initial
  , currentV :: TVar I.Current
  }

type TaskOf a = ReaderT TaskParams IO a
type Task = TaskOf ()

askId :: TaskOf I.TaskId
askId = asks (I.taskId . initial)

-- internal
askCurrentV :: TaskOf (TVar I.Current)
askCurrentV = asks currentV

modifyProgress :: (I.Progress -> I.Progress) -> TaskOf ()
modifyProgress f = do
  c <- askCurrentV
  lift $ atomically $ modifyTVar' c (Left . f . fromLeft')

setPhase :: String -> TaskOf ()
setPhase s = modifyProgress (\p -> p { I.phase = s })

setTotalWork :: Int -> TaskOf ()
setTotalWork x = modifyProgress (\p -> p { I.totalWork = x})

setDoneWork :: Int -> TaskOf ()
setDoneWork x = modifyProgress (\p -> p { I.doneWork = x})
