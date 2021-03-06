{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}
{-# LANGUAGE RecordWildCards #-}

-- ----------------------------------------------------------------------------------------- --

module CoreUtils

-- ----------------------------------------------------------------------------------------- --
-- 
-- Utilities for Core
-- 
-- ----------------------------------------------------------------------------------------- --
-- export

( filterEnvCtoEnvB  -- :: IOC.IOC IOB.EnvB
, writeEnvBtoEnvC   -- :: IOB.EnvB -> IOC.IOC ()
, isInCTOffers      -- :: Set.Set BTree.CTOffer -> IOC.IOC Bool
, isOutCTOffers     -- :: Set.Set BTree.CTOffer -> IOC.IOC Bool
, isInAct           -- :: TxsDDefs.Action -> IOC.IOC Bool
, nextBehTrie       -- :: TxsDDefs.Action -> IOC.IOC ()
, randMenu          -- :: BTree.Menu -> IOC.IOC (Maybe TxsDDefs.Action)
, randPurpMenu      -- :: BTree.Menu -> [BTree.Menu] -> IOC.IOC (Maybe TxsDDefs.Action)
, menuConjunct      -- :: BTree.Menu -> BTree.Menu -> BTree.Menu
, menuConjuncts     -- :: [BTree.Menu] -> BTree.Menu
)

-- ----------------------------------------------------------------------------------------- --
-- import 

where

import System.Random
import Control.Monad.State

import qualified Data.Set  as Set
import qualified Data.Map  as Map
import           Data.Maybe

-- import from behavedef
import qualified BTree

-- import from behaveenv
import qualified EnvCore   as IOC
import qualified EnvBTree  as IOB

-- import from defs
import qualified TxsDefs
import qualified TxsDDefs
import qualified Sigs
import qualified SolveDefs
import qualified Solve

-- import from valexpr
import ConstDefs
import ValExpr

-- ----------------------------------------------------------------------------------------- --
-- filterEnvCtoEnvB


filterEnvCtoEnvB :: IOC.IOC IOB.EnvB
filterEnvCtoEnvB = do
     envc <- get
     case IOC.state envc of
       IOC.Noning
         -> return IOB.EnvB { IOB.smts     = Map.empty
                            , IOB.tdefs    = TxsDefs.empty
                            , IOB.sigs     = Sigs.empty
                            , IOB.stateid  = 0
                            , IOB.params   = IOC.params envc
                            , IOB.unid     = IOC.unid envc
                            , IOB.msgs     = []
                            }
       IOC.Initing{..}
         -> return IOB.EnvB { IOB.smts     = smts
                            , IOB.tdefs    = tdefs
                            , IOB.sigs     = sigs
                            , IOB.stateid  = 0
                            , IOB.params   = IOC.params envc
                            , IOB.unid     = IOC.unid envc
                            , IOB.msgs     = []
                            }
       IOC.Testing{..}
         -> return IOB.EnvB { IOB.smts     = smts
                            , IOB.tdefs    = tdefs
                            , IOB.sigs     = sigs
                            , IOB.stateid  = curstate
                            , IOB.params   = IOC.params envc
                            , IOB.unid     = IOC.unid envc
                            , IOB.msgs     = []
                            }
       IOC.Simuling{..}
         -> return IOB.EnvB { IOB.smts     = smts
                            , IOB.tdefs    = tdefs
                            , IOB.sigs     = sigs
                            , IOB.stateid  = curstate
                            , IOB.params   = IOC.params envc
                            , IOB.unid     = IOC.unid envc
                            , IOB.msgs     = []
                            }
       IOC.Stepping{..}
         -> return IOB.EnvB { IOB.smts     = smts
                            , IOB.tdefs    = tdefs
                            , IOB.sigs     = sigs
                            , IOB.stateid  = curstate
                            , IOB.params   = IOC.params envc
                            , IOB.unid     = IOC.unid envc
                            , IOB.msgs     = []
                            }

-- ----------------------------------------------------------------------------------------- --
-- filterEnvCtoEnvB

writeEnvBtoEnvC :: IOB.EnvB -> IOC.IOC ()
writeEnvBtoEnvC envb = do
  putMsgs <- gets (IOC.putmsgs . IOC.state)
  putMsgs $ IOB.msgs envb
  modify $ \env -> env { IOC.unid = IOB.unid envb }

-- ----------------------------------------------------------------------------------------- --
-- isInCTOffers  :  is input offer?

isInCTOffers :: Set.Set BTree.CTOffer -> IOC.IOC Bool
isInCTOffers ctoffers = do
     TxsDefs.ModelDef insyncs outsyncs _splsyncs _bexp <- gets (IOC.modeldef . IOC.state)
     let chinset  = Set.unions insyncs
         choutset = Set.unions outsyncs
         chanids  = Set.map BTree.ctchan ctoffers
     return $    not (Set.null (chanids `Set.intersection` chinset))
              &&      Set.null (chanids `Set.intersection` choutset)


isInAct :: TxsDDefs.Action -> IOC.IOC Bool

isInAct (TxsDDefs.Act acts) = do
     TxsDefs.ModelDef insyncs outsyncs _splsyncs _bexp <- gets (IOC.modeldef . IOC.state)
     let chinset  = Set.unions insyncs
         choutset = Set.unions outsyncs
         chanids  = Set.map fst acts
     return $    not (Set.null (chanids `Set.intersection` chinset))
              &&      Set.null (chanids `Set.intersection` choutset)

isInAct TxsDDefs.ActQui = return False

-- ----------------------------------------------------------------------------------------- --
-- isOutCTOffers :  is output offer?

isOutCTOffers :: Set.Set BTree.CTOffer -> IOC.IOC Bool
isOutCTOffers ctoffers = do
     TxsDefs.ModelDef insyncs outsyncs _splsyncs _bexp <- gets (IOC.modeldef . IOC.state)
     let chinset  = Set.unions insyncs
         choutset = Set.unions outsyncs
         chanids  = Set.map BTree.ctchan ctoffers
     return $         Set.null (chanids `Set.intersection` chinset)
              && not (Set.null (chanids `Set.intersection` choutset))

-- ----------------------------------------------------------------------------------------- --
-- nextBehTrie :  update behtrie and curstate

nextBehTrie :: TxsDDefs.Action -> IOC.IOC ()
nextBehTrie act = do
     envc <- get
     case IOC.state envc of
       IOC.Noning {} -> return ()
       IOC.Initing {} -> return ()
       IOC.Testing { IOC.behtrie = behtrie
                   , IOC.curstate = curstate
                   } ->
         IOC.modifyCS $
           \st -> st { IOC.behtrie  = behtrie ++ [(curstate, act, curstate+1)]
                     , IOC.curstate = curstate + 1
                     }
       IOC.Simuling { IOC.behtrie = behtrie
                    , IOC.curstate = curstate
                    } ->
         IOC.modifyCS $
           \st -> st { IOC.behtrie  = behtrie ++ [(curstate, act, curstate+1)]
                     , IOC.curstate = curstate + 1
                     }
       IOC.Stepping { IOC.behtrie = behtrie
                    , IOC.curstate = curstate
                    , IOC.maxstate = maxstate
                    } ->
         IOC.modifyCS $
           \st -> st { IOC.behtrie  = behtrie ++ [(curstate, act, maxstate+1)]
                     , IOC.curstate = maxstate+1
                     , IOC.maxstate = maxstate+1
                     }

-- ----------------------------------------------------------------------------------------- --
-- randMenu :  menu randomization

randMenu :: BTree.Menu -> IOC.IOC (Maybe TxsDDefs.Action)
randMenu menu =
     if null menu
       then return Nothing
       else do
         relem <- lift $ randomRIO (0, length menu - 1)
         let (pre, x:post) = splitAt relem menu
             (ctoffs, hvars, pred')  = x
             menu'                  = pre++post
             vvars                  = concatMap BTree.ctchoffers (Set.toList ctoffs)
             ivars                  = vvars ++ hvars
             assertions             = Solve.add pred' Solve.empty
         smtEnv   <- IOC.getSMT "current"
         parammap <- gets IOC.params
         let p = Solve.toRandParam parammap
         (sat,smtEnv') <- lift $ runStateT (Solve.randSolve p ivars assertions) smtEnv
         IOC.putSMT "current" smtEnv'
         case sat of
           SolveDefs.Solved sol    -> return $ Just $
                                           TxsDDefs.Act (Set.map (instantCTOffer sol) ctoffs)
           SolveDefs.Unsolvable    -> randMenu menu'
           SolveDefs.UnableToSolve -> randMenu menu'

instantCTOffer :: Map.Map BTree.IVar Const -> BTree.CTOffer ->
                  (TxsDefs.ChanId, [Const])
instantCTOffer sol (BTree.CToffer chan choffs)
 = ( chan, map (instantIVar sol) choffs )

instantIVar :: Map.Map BTree.IVar Const -> BTree.IVar -> Const
instantIVar sol ivar
 =   fromMaybe
      (error "TXS Test ranMenuIn: No value for interaction variable\n")
      (Map.lookup ivar sol)

-- ----------------------------------------------------------------------------------------- --
-- combine menu with purpose menus

randPurpMenu :: BTree.Menu -> [BTree.Menu] -> IOC.IOC (Maybe TxsDDefs.Action)
randPurpMenu modmenu purpmenus =
     if null purpmenus
       then return Nothing
       else do
         rpurp      <- lift $ randomRIO (0, length purpmenus - 1)
         let (pre, purpmenu:post) = splitAt rpurp purpmenus
             purpmenus' = pre++post
         mayAct     <- randMenu (modmenu `menuConjunct` purpmenu)
         case mayAct of
           Just act -> return $ Just act
           Nothing  -> randPurpMenu modmenu purpmenus'

-- ----------------------------------------------------------------------------------------- --
-- conjunction of menus

menuConjunct :: BTree.Menu -> BTree.Menu -> BTree.Menu
menuConjunct menu1 menu2
 = [ (ctoffs1,hvars1 ++ hvars2, cstrAnd (Set.fromList [pred1,pred2]) )
   | (ctoffs1,hvars1,pred1) <- menu1
   , (ctoffs2,hvars2,pred2) <- menu2
   , ctoffs1 == ctoffs2
   ]


menuConjuncts :: [BTree.Menu] -> BTree.Menu
menuConjuncts []           = []
menuConjuncts [menu]       = menu
menuConjuncts (menu:menus) = menuConjunct menu (menuConjuncts menus)

-- ----------------------------------------------------------------------------------------- --
--                                                                                           --
-- ----------------------------------------------------------------------------------------- --

