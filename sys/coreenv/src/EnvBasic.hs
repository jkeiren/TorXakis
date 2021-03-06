{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}

-- | Basic Part of TorXakis Core Environment (Internal State) Data Type Definitions.
module EnvBasic
  (
    EnvB(..)
  )
where

import qualified EnvData
import qualified Id
import qualified Data.Map            as Map
import Name
import VarId


-- ----------------------------------------------------------------------------------------- --
-- class for monad dependency

class (Monad envb) => EnvB envb
  where
     newUnid :: envb Id.Id
     putMsgs :: [EnvData.Msg] -> envb ()
     setChanoffers :: Map.Map (Name, Int) VarId -> envb ()
     getChanoffers :: envb (Map.Map (Name, Int) VarId)


-- ----------------------------------------------------------------------------------------- --
--
-- ----------------------------------------------------------------------------------------- --

