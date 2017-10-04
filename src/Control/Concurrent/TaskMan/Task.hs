module Control.Concurrent.TaskMan.Task where

import qualified Control.Concurrent.TaskMan.Task.Info as I

import Control.Monad.Reader (ReaderT, asks, lift)
import Control.Concurrent.STM (TVar, atomically, modifyTVar')
import Data.Either.Combinators (fromLeft')
import Control.Lens

data TaskParams = TaskParams
  { initial :: I.Initial
  , currentV :: TVar I.Current
  }

type Task a = ReaderT TaskParams IO a

askId :: Task I.TaskId
askId = asks (view I.taskId . initial)

-- internal
askCurrentV :: Task (TVar I.Current)
askCurrentV = asks currentV

modifyProgress :: (I.Progress -> I.Progress) -> Task ()
modifyProgress f = do
  c <- askCurrentV
  lift $ atomically $ modifyTVar' c (Left . f . fromLeft')

setProgress :: I.Progress -> Task ()
setProgress p = modifyProgress (const p)

setPhase :: String -> Task ()
setPhase s = modifyProgress (set I.phase s)

setTotalWork :: Int -> Task ()
setTotalWork x = modifyProgress (set I.totalWork x)

setDoneWork :: Int -> Task ()
setDoneWork x = modifyProgress (set I.doneWork x)
