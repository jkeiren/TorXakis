{-
TorXakis - Model Based Testing
Copyright (c) 2015-2017 TNO and Radboud University
See LICENSE at root directory of this repository.
-}


-----------------------------------------------------------------------------
-- |
-- Module      :  LPE
-- Copyright   :  TNO and Radboud University
-- License     :  BSD3
-- Maintainer  :  carsten.ruetz, jan.tretmans
-- Stability   :  experimental
--
-----------------------------------------------------------------------------

{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ViewPatterns        #-}
-- TODO: make sure these warnings are removed.
-- TODO: also check the hlint warnings!
{-# OPTIONS_GHC -Wno-name-shadowing #-}
{-# OPTIONS_GHC -Wno-unused-matches #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# OPTIONS_GHC -Wno-unused-local-binds #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# OPTIONS_GHC -Wno-unused-imports #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}

module LPE
( ProcDefs
, preGNF
, gnf
, lpeTransform
, lpe
, lpePar
, lpeHide
)

where

-- ----------------------------------------------------------------------------------------- --
-- import

import Debug.Trace
import Control.Monad.State

import qualified Data.Map            as Map
import qualified Data.Set            as Set
import qualified Data.Text           as T
import           Data.Maybe
import           Data.Monoid
import qualified Control.Arrow

import TranslatedProcDefs

import TxsDefs
import ConstDefs
import StdTDefs (stdSortTable, chanIdIstep)

import ChanId
import ProcId
import SortId
import VarId
import Name

import BehExprDefs
import ValExpr
import qualified TxsUtils

import qualified EnvData
import qualified EnvBasic            as EnvB

import Expand (relabel)
import Subst

-- ----------------------------------------------------------------------------------------- --
-- Types :
-- ----------------------------------------------------------------------------------------- --

type ProcDefs = Map.Map ProcId ProcDef

type Proc = (ProcId, [ChanId])
type PCMapping = Map.Map Proc Integer
type ProcToParams = Map.Map Proc [VarId]

type ChanMapping = Map.Map ChanId ChanId
type ParamMapping = Map.Map VarId VExpr

intSort = fromMaybe (error "LPE module: could not find standard IntSort") (Map.lookup (T.pack "Int") stdSortTable)


-- ----------------------------------------------------------------------------------------- --
-- Helpers :
-- ----------------------------------------------------------------------------------------- --

extractVars :: ActOffer -> [VarId]
extractVars actOffer = let  set = offers actOffer in
                       Set.foldr collect [] set
    where
        collect :: Offer -> [VarId] -> [VarId]
        collect Offer{chanoffers = coffers} varIds = foldr extractVarIds [] coffers

        extractVarIds :: ChanOffer -> [VarId] -> [VarId]
        extractVarIds (Quest varId) varIds  = varId:varIds
        extractVarIds _ varIds              = varIds



wrapSteps :: [BExpr] -> BExpr
wrapSteps [bexpr] = bexpr
wrapSteps bexprs = choice bexprs

extractSteps :: BExpr -> [BExpr]
extractSteps (TxsDefs.view -> Choice bexprs) = bexprs
extractSteps bexpr = [bexpr]

-- ----------------------------------------------------------------------------------------- --
-- preGNF :
-- ----------------------------------------------------------------------------------------- --
--
preGNF :: (EnvB.EnvB envb) => ProcId -> TranslatedProcDefs -> ProcDefs -> envb ProcDefs
preGNF procId translatedProcDefs procDefs = do
    let -- decompose the ProcDef of ProcId
        ProcDef chansDef paramsDef bexpr = fromMaybe (error "called preGNF with a non-existing procId") (Map.lookup procId procDefs)
        -- remember the current ProcId to avoid recursive loops translating the same ProcId again
        translatedProcDefs' = translatedProcDefs { lPreGNF = lPreGNF translatedProcDefs ++ [procId]}
        -- translate each choice separately

    (procDef', procDefs') <- case TxsDefs.view bexpr of
                              (Choice bexprs) -> do  (bexprs', procDefs') <-  applyPreGNFBexpr bexprs 1 [] translatedProcDefs' procDefs
                                                     let procDef' = ProcDef chansDef paramsDef (choice bexprs')
                                                     return (procDef', procDefs')

                              _               -> do  (bexpr', procDefs') <- preGNFBExpr bexpr 1 [] procId translatedProcDefs' procDefs
                                                     let procDef' = ProcDef chansDef paramsDef bexpr'
                                                     return (procDef', procDefs')
    return $ Map.insert procId procDef' procDefs'
    where
        -- apply preGNFBExpr to each choice and collect all intermediate results (single bexprs)
        applyPreGNFBexpr :: (EnvB.EnvB envb) => [BExpr] -> Int -> [BExpr] -> TranslatedProcDefs -> ProcDefs -> envb ([BExpr], ProcDefs)
        applyPreGNFBexpr [] cnt results translatedProcDefs procDefs = return (results, procDefs)
        applyPreGNFBexpr (bexpr:bexprs) cnt results translatedProcDefs procDefs = do
                (bexpr', procDefs') <- preGNFBExpr bexpr cnt [] procId translatedProcDefs procDefs
                applyPreGNFBexpr bexprs (cnt+1) (results ++ [bexpr']) translatedProcDefs procDefs'



preGNFBExpr :: (EnvB.EnvB envb) => BExpr -> Int -> [VarId] -> ProcId -> TranslatedProcDefs -> ProcDefs -> envb(BExpr, ProcDefs)

preGNFBExpr (TxsDefs.view -> Stop) _ _ _ _ procDefs =
    return (stop, procDefs)

preGNFBExpr bexpr@(TxsDefs.view -> ActionPref actOffer bexpr') choiceCnt freeVarsInScope procId translatedProcDefs procDefs = do
    let freeVarsInScope' = freeVarsInScope ++ extractVars actOffer
    (bexpr'', procDefs') <- preGNFBExpr bexpr' choiceCnt freeVarsInScope' procId translatedProcDefs procDefs
    return (actionPref actOffer bexpr'', procDefs')

preGNFBExpr bexpr@(TxsDefs.view -> ProcInst procIdInst _ _) choiceCnt freeVarsInScope procId translatedProcDefs procDefs =
  if procIdInst `notElem` lPreGNF translatedProcDefs
      then  do -- recursively translate the called ProcDef
               procDefs' <- preGNF procIdInst translatedProcDefs procDefs
               return (bexpr, procDefs')
      else  return (bexpr, procDefs)


preGNFBExpr bexpr@(TxsDefs.view -> Choice bexprs) choiceCnt freeVarsInScope procId translatedProcDefs procDefs = do
    -- choice at lower level not allowed
    (procInst'@(TxsDefs.view -> ProcInst procId' _ _), procDefs') <- preGNFBExprCreateProcDef bexpr choiceCnt freeVarsInScope procId procDefs
    -- recursively translate the created ProcDef
    procDefs'' <- preGNF procId' translatedProcDefs procDefs'
    return (procInst', procDefs'')

preGNFBExpr bexpr@(TxsDefs.view -> Parallel syncChans operands) choiceCnt freeVarsInScope procId translatedProcDefs procDefs = do
    -- parallel at lower level not allowed
    (procInst', procDefs') <- preGNFBExprCreateProcDef bexpr choiceCnt freeVarsInScope procId procDefs
    -- translate the created ProcDef with LPEPar
    (procInst'', procDefs'') <- lpePar procInst' translatedProcDefs procDefs'
    return (procInst'', procDefs'')


preGNFBExpr bexpr@(TxsDefs.view -> Hide hiddenChans bexpr') choiceCnt freeVarsInScope procId translatedProcDefs procDefs = do
    -- HIDE at lower level not allowed
    (procInst', procDefs') <- preGNFBExprCreateProcDef bexpr choiceCnt freeVarsInScope procId procDefs
    -- translate the created ProcDef with LPEHide
    res <- lpeHide procInst' translatedProcDefs procDefs' 
    trace ("\n\nres: " ++ show res) $ return $ res

preGNFBExpr _ _ _ _ _ _ =
    error "unexpected type of bexpr"


preGNFBExprCreateProcDef :: (EnvB.EnvB envb) => BExpr -> Int -> [VarId] -> ProcId -> ProcDefs -> envb(BExpr, ProcDefs)
preGNFBExprCreateProcDef bexpr choiceCnt freeVarsInScope procId procDefs = do
    unid <- EnvB.newUnid
    let -- decompose the ProcDef of ProcId
        ProcDef chansDef paramsDef _ = fromMaybe (error "called preGNFBExpr with a non-existing procId") (Map.lookup procId procDefs)

        -- create new ProcDef
        procDef' = ProcDef chansDef (paramsDef ++ freeVarsInScope) bexpr
        -- create new ProcId
        name' = T.append (ProcId.name procId) (T.pack ("$pre" ++ show choiceCnt))
        procId' = procId { ProcId.name = name',
                            ProcId.unid = unid,
                            ProcId.procvars = paramsDef ++ freeVarsInScope}
        -- create ProcInst, translate params to VExprs
        paramsDef' = map cstrVar paramsDef
        paramsFreeVars = map cstrVar freeVarsInScope
        procInst' = procInst procId' chansDef (paramsDef' ++ paramsFreeVars)
        -- put created ProcDefs in the ProcDefs
        procDefs' = Map.insert procId' procDef' procDefs
    return (procInst', procDefs')

-- ----------------------------------------------------------------------------------------- --
-- GNF :
-- ----------------------------------------------------------------------------------------- --

gnf :: (EnvB.EnvB envb) => ProcId -> TranslatedProcDefs -> ProcDefs -> envb ProcDefs
gnf procId translatedProcDefs procDefs = do
    -- first translate to preGNF
    procDefs' <- preGNF procId emptyTranslatedProcDefs procDefs

    -- remember the current ProcId to avoid recursive loops translating the same ProcId again
    -- also remember a chain of direct calls (without progress, i.e. no ActionPref) to detect loops
    let translatedProcDefs' = translatedProcDefs { lGNF = lGNF translatedProcDefs ++ [procId]
                                                 , lGNFdirectcalls = lGNFdirectcalls translatedProcDefs ++ [procId]}
        ProcDef chansDef paramsDef bexpr = fromMaybe (error "GNF: could not find given procId (should be impossible)") (Map.lookup procId procDefs')

    (procDef, procDefs'') <- case TxsDefs.view bexpr of
                                (Choice bexprs) -> do   (steps, procDefs'') <- applyGNFBexpr bexprs 1 [] translatedProcDefs' procDefs'
                                                        let procDef = ProcDef chansDef paramsDef (choice steps)
                                                        return (procDef, procDefs'')
                                _               -> do   (steps, procDefs'') <- gnfBExpr bexpr 1 procId translatedProcDefs' procDefs'
                                                        let procDef = ProcDef chansDef paramsDef (wrapSteps steps)
                                                        return (procDef, procDefs'')
    return $ Map.insert procId procDef procDefs''
      where
        -- apply gnfBExpr to each choice and collect all intermediate results (single bexprs)
        applyGNFBexpr :: (EnvB.EnvB envb) => [BExpr] -> Int -> [BExpr] -> TranslatedProcDefs -> ProcDefs -> envb ([BExpr], ProcDefs)
        applyGNFBexpr [] cnt results translatedProcDefs procDefs = return (results, procDefs)
        applyGNFBexpr (bexpr:bexprs) cnt results translatedProcDefs procDefs = do
                -- return (results, procDefs)
                (steps, procDefs') <- gnfBExpr bexpr cnt procId translatedProcDefs procDefs
                applyGNFBexpr bexprs (cnt+1) (results ++ steps) translatedProcDefs procDefs'


gnfBExpr :: (EnvB.EnvB envb) => BExpr -> Int -> ProcId -> TranslatedProcDefs -> ProcDefs -> envb([BExpr], ProcDefs)
gnfBExpr bexpr@(TxsDefs.view -> Stop) choiceCnt procId translatedProcDefs procDefs =
      return ([bexpr], procDefs)

gnfBExpr bexpr@(TxsDefs.view -> ActionPref actOffer (TxsDefs.view -> Stop)) choiceCnt procId translatedProcDefs procDefs =
      return ([bexpr], procDefs)

gnfBExpr bexpr@(TxsDefs.view -> ActionPref actOffer (TxsDefs.view -> ProcInst procIdInst _ _)) choiceCnt procId translatedProcDefs procDefs =
  if procIdInst `notElem` lGNF translatedProcDefs
      then    do  -- recursively translate the called ProcDef
                  -- reset GNF loop detection: we made progress, thus we are breaking a possible chain of direct calls (ProcInsts)
                  let translatedProcDefs' = translatedProcDefs { lGNFdirectcalls = []}
                  procDefs' <- gnf procIdInst translatedProcDefs' procDefs
                  return ([bexpr], procDefs')
      else    return ([bexpr], procDefs)

gnfBExpr bexpr@(TxsDefs.view -> ActionPref actOffer bexpr') choiceCnt procId translatedProcDefs procDefs = do
    unidProcInst <- EnvB.newUnid
    let -- multi-action not allowed: split it
        -- decompose original ProcDef
        ProcDef chansDef paramsDef _ = fromMaybe (error "GNF: called with a non-existing procId") (Map.lookup procId procDefs)

        -- create new ProcDef
        varsInOffer = extractVars actOffer
        procDef = ProcDef chansDef (paramsDef ++ varsInOffer) bexpr'

        -- create ProcInst calling that ProcDef
        name' = T.append (ProcId.name procId) (T.pack ("$gnf" ++ show choiceCnt))
        procId' = procId { ProcId.name = name',
                            ProcId.unid = unidProcInst,
                            ProcId.procvars = paramsDef ++ varsInOffer}
        -- create ProcInst, translate params to VExprs
        paramsDef' = map cstrVar paramsDef
        paramsFreeVars = map cstrVar varsInOffer
        procInst' = procInst procId' chansDef (paramsDef' ++ paramsFreeVars)

        -- put created ProcDefs in the ProcDefs
        procDefs' = Map.insert procId' procDef procDefs

        -- reset GNF loop detection: we made progress, thus we are breaking a possible chain of direct calls (ProcInsts)
        translatedProcDefs' = translatedProcDefs { lGNFdirectcalls = []}
        
    -- recursively translate the created ProcDef
    procDefs'' <- gnf procId' translatedProcDefs' procDefs'
    -- return bexpr with the original bexpr' replaced with the new ProcInst
    return ([actionPref actOffer procInst'], procDefs'')


gnfBExpr bexpr@(TxsDefs.view -> ProcInst procIdInst chansInst paramsInst) choiceCnt procId translatedProcDefs procDefs = do
    -- direct calls are not in GNF: need to instantiate
    -- translate procIdInst to GNF first            
    --   -- we made progress (i.e. we have an ActionPref), thus reset no-progress-loop detection
            --   translatedProcDefs' = translatedProcDefs { lGNFnoprogress = []}
    
        
    -- check if we encounter a loop of direct calls
    --  i.e. a chain of procInsts without any ActionPref, thus we would make no progress
    --  this endless loop cannot be translated to GNF
    -- trace ("\ndirect ProcInst case: " ++ (show bexpr) ++ "\n") $
    if procIdInst `elem` lGNFdirectcalls translatedProcDefs
        then do -- found a loop
                let loop = map ProcId.name $ lGNFdirectcalls translatedProcDefs ++ [procIdInst]
                -- trace ("\nfound GNF loop " ++ (show loop) ++ "\n") $ 
                error ("found GNF loop of direct calls without progress: " ++ (show loop))
        else do -- no loop
                -- check if the called ProcDef has been translated to GNF already
                procDefs' <- if procIdInst `notElem` lGNF translatedProcDefs
                                    then    -- recursively translate the called ProcDef
                                            gnf procIdInst translatedProcDefs procDefs
                                    else    -- if it has been translated already, leave procDefs as is
                                            return procDefs

                let -- decompose translated ProcDef
                    ProcDef chansDef paramsDef bexprDef = fromMaybe (error "GNF: called with a non-existing procId") (Map.lookup procIdInst procDefs')

                    -- instantiate
                    -- substitute channels
                    chanmap = Map.fromList (zip chansDef chansInst)
                    bexprRelabeled = relabel chanmap bexprDef -- trace ("chanmap: " ++ show chanmap) relabel chanmap bexprProcDef
                    -- substitute params
                    parammap = Map.fromList (zip paramsDef paramsInst)
                    -- TODO: initialise funcDefs param properly
                    bexprSubstituted = Subst.subst parammap (Map.fromList []) bexprRelabeled
                return (extractSteps bexprSubstituted, procDefs')


gnfBExpr _ _ _ _ _ =
    error "not implemented"



-- ----------------------------------------------------------------------------------------- --
-- lpePar :
-- ----------------------------------------------------------------------------------------- --

-- we assume that the top level bexpr of the called ProcDef is Parallel
lpePar :: (EnvB.EnvB envb) => BExpr -> TranslatedProcDefs -> ProcDefs -> envb(BExpr, ProcDefs)
lpePar (TxsDefs.view -> ProcInst procIdInst chansInst paramsInst) translatedProcDefs procDefs = do
    let -- get and decompose ProcDef and the parallel bexpr
      ProcDef chansDef paramsDef bexpr = fromMaybe (error "lpePar: could not find the given procId") (Map.lookup procIdInst procDefs)
      Parallel syncChans ops = TxsDefs.view bexpr

      -- translate the operands to LPE first
      -- collect (in accu) per operand: translated steps, the generated procInst
      --  and a changed mapping of procDefs
    (_, stepsOpParams, paramsInsts, procDefs') <- foldM translateOperand (1, [],[], procDefs) ops

    unid <- EnvB.newUnid
    let -- create a new ProcId
        chansDefPAR = chansDef
        paramsDefPAR = concatMap snd stepsOpParams
        procIdPAR = procIdInst { ProcId.procchans = chansDefPAR,
                                  ProcId.unid = unid,
                                  ProcId.procvars = paramsDefPAR}

        -- combine the steps of all operands according to parallel semantics
        -- stepOpParams is a list of pairs, one pair for each operand:
        --    pair = (steps, paramsDef)
        stepsOpParams_out = concat $ map (\s -> (show s) ++ "\n") stepsOpParams
        (stepsPAR, _) = foldr1 (combineSteps syncChans procIdPAR chansDefPAR) stepsOpParams

        -- create a new ProcId, ProcDef, ProcInst
        procDefPAR = ProcDef chansDefPAR paramsDefPAR (wrapSteps stepsPAR)
        procDefsPAR = Map.insert procIdPAR procDefPAR procDefs'
        procInstPAR = procInst procIdPAR chansInst paramsInsts
    return (procInstPAR, procDefsPAR)
    where
      -- takes two operands (steps and paramsDef) and combines them according to parallel semantics
      combineSteps :: [ChanId] -> ProcId -> [ChanId] -> ([BExpr], [VarId]) -> ([BExpr], [VarId]) ->  ([BExpr], [VarId])
      combineSteps syncChans procIdPAR chansDefPAR (stepsL, opParamsL) (stepsR, opParamsR) =
        let -- first only steps of the left operand
            stepsLvalid = filter (isValidStep syncChans) stepsL
            stepsL' = map (updateProcInstL opParamsR procIdPAR chansDefPAR) stepsLvalid
            -- second only steps of the right operand
            stepsRvalid = filter (isValidStep syncChans) stepsR
            stepsR' = map (updateProcInstR opParamsL procIdPAR chansDefPAR) stepsRvalid
            -- finally steps of both operands
            -- stepCombinations :: [(BExpr, BExpr)]
            stepCombinations = [(l,r) | l <- stepsL, r <- stepsR]
            -- stepCombinationsValid :: [(BExpr, BExpr)]
            stepCombinationsValid = filter (isValidStepCombination syncChans) stepCombinations
            stepsLR = map (mergeStepsLR procIdPAR chansDefPAR opParamsL opParamsR) stepCombinationsValid
        in
        -- TODO: optimize complexity of this: might be MANY steps...
        (stepsL' ++ stepsR' ++ stepsLR, opParamsL ++ opParamsR)
        where
          mergeStepsLR :: ProcId -> [ChanId] -> [VarId] -> [VarId] -> (BExpr, BExpr) -> BExpr
          mergeStepsLR procIdPAR chansDefPar opParamsL opParamsR (stepL, stepR) =
            let -- decompose steps
                ActionPref ActOffer{offers=offersL, constraint=constraintL} bL = TxsDefs.view stepL
                ProcInst procIdL chansL paramsL = TxsDefs.view bL
                ActionPref ActOffer{offers=offersR, constraint=constraintR} bR = TxsDefs.view stepR
                ProcInst procIdR chansR paramsR = TxsDefs.view bR

                -- combine action offers
                --  union of offers, concatenation of constraints
                -- offersLR = trace ("\ncombining: " ++ (show offersL) ++ " and " ++ (show offersR)) $ Set.union offersL offersR
                offersLR = Set.union offersL offersR

                -- constraintLR = trace ("\nconstraints: " ++ (show constraintL) ++ " and " ++ (show constraintR)) $ cstrAnd (Set.fromList [constraintL, constraintR])
                constraintLR = cstrAnd (Set.fromList [constraintL, constraintR])

                -- new ActOffers and ProcInst
                actOfferLR = ActOffer { offers = offersLR,
                                        constraint = constraintLR}
                procInstLR = procInst procIdPAR chansDefPar (paramsL ++ paramsR)
            in
            actionPref actOfferLR procInstLR

          -- check if given step can be executed by itself according to parallel semantics
          isValidStep :: [ChanId] -> BExpr -> Bool
          isValidStep syncChans (TxsDefs.view -> ActionPref ActOffer{offers=os} _) =
            let -- extract all chanIds from the offers in the ActOffer
                chanIds = Set.foldl (\accu offer -> (chanid offer : accu)) [] os in
            -- if there are no common channels with the synchronisation channels: return true
            Set.null $ Set.intersection (Set.fromList syncChans) (Set.fromList chanIds)

          -- check if given step combination can be executed according to parallel semantics
          isValidStepCombination :: [ChanId] -> (BExpr, BExpr) -> Bool
          isValidStepCombination syncChans (TxsDefs.view -> ActionPref ActOffer{offers=offersL} _, TxsDefs.view -> ActionPref ActOffer{offers=offersR} _) =
            let -- extract all chanIds from the offers in the ActOffer
                chanIdsLSet = Set.fromList $ Set.foldl (\accu offer -> (chanid offer : accu)) [] offersL
                chanIdsRSet = Set.fromList $ Set.foldl (\accu offer -> (chanid offer : accu)) [] offersR
                syncChansSet = Set.fromList syncChans

                intersectionLR = Set.intersection chanIdsLSet chanIdsRSet
                intersectionLsyncChans = Set.intersection chanIdsLSet syncChansSet
                intersectionRsyncChans = Set.intersection chanIdsRSet syncChansSet
            in
            (intersectionLR == intersectionLsyncChans) && (intersectionLsyncChans == intersectionRsyncChans)


          updateProcInstL :: [VarId] -> ProcId -> [ChanId] -> BExpr -> BExpr
          updateProcInstL opParamsR procIdPAR chansDefPar (TxsDefs.view -> ActionPref actOfferL (TxsDefs.view -> ProcInst procIdInstL chansInstL paramsInstL)) =
              actionPref actOfferL (procInst procIdPAR chansDefPar (paramsInstL ++ map cstrVar opParamsR))
          updateProcInstR :: [VarId] -> ProcId -> [ChanId] -> BExpr -> BExpr
          updateProcInstR opParamsL procIdPAR chansDefPar (TxsDefs.view -> ActionPref actOfferR (TxsDefs.view -> ProcInst procIdInstR chansInstR paramsInstR)) =
              actionPref actOfferR (procInst procIdPAR chansDefPar (map cstrVar opParamsL ++ paramsInstR))

      -- accu = (opNr, steps, params, procDefs)
      -- foldl : (a -> b -> a) -> a -> [b] -> a
      -- a = (opNr, steps, params, procDefs)
      -- b = BExpr
      -- transform list of bexprs to our big accu combination
      translateOperand :: (EnvB.EnvB envb) => (Int, [([BExpr], [VarId])], [VExpr], ProcDefs ) -> BExpr -> envb (Int, [([BExpr], [VarId])], [VExpr], ProcDefs)
      translateOperand (opNr, stepsOpParams, paramsInsts, procDefs) operand = do
        -- translate operand to ProcInst if necessary
        (opProcInst, procDefs') <- transformToProcInst operand procIdInst procDefs
        -- translate to lpe
        (procInstLPE@(TxsDefs.view -> ProcInst procIdLPE chansInstLPE paramsInstLPE), procDefs'') <- lpe opProcInst translatedProcDefs procDefs'

        let -- decompose translated ProcDef
            ProcDef chansDef paramsDef bexpr = fromMaybe (error "translateOperand: could not find the given procId") (Map.lookup procIdLPE procDefs'')

            -- instantiate the channels
            chanmap = Map.fromList (zip chansDef chansInstLPE)
            bexpr' = relabel chanmap bexpr
            -- prefix the params and wrap them as VExpr just to be able to use the substitution function later
            prefix = "op" ++ show opNr ++ "$"
            -- TODO: create new unids as well!
        paramsDefPrefixed <- mapM (prefixVarId prefix) paramsDef
        let paramMap = Map.fromList $ zip paramsDef (map cstrVar paramsDefPrefixed)
            -- TODO: properly initialise funcDefs param of subst
            bexpr'' = Subst.subst paramMap (Map.fromList []) bexpr'
        return (opNr+1, stepsOpParams ++ [(extractSteps bexpr'', paramsDefPrefixed)], paramsInsts ++ paramsInstLPE, procDefs'')
          where
            prefixVarId :: (EnvB.EnvB envb) => String -> VarId -> envb VarId
            prefixVarId prefix (VarId name _ sort) = do
                unid <- EnvB.newUnid
                let name' = T.pack $ prefix ++ T.unpack name
                return $ VarId name' unid sort

            transformToProcInst :: (EnvB.EnvB envb) => BExpr -> ProcId -> ProcDefs -> envb(BExpr, ProcDefs)
            -- if operand is already a ProcInst: no need to change anything
            transformToProcInst bexpr@(TxsDefs.view -> ProcInst{}) procIdParent procDefs = return (bexpr, procDefs)
            -- otherwise: create new ProcDef and ProcInst
            transformToProcInst operand procIdParent procDefs = do
              unid <- EnvB.newUnid
              let -- decompose parent ProcDef
                  ProcDef chansDef paramsDef bexpr = fromMaybe (error "transformToProcInst: could not find the given procId") (Map.lookup procIdParent procDefs)
                  -- create new ProcDef and ProcInst
                  procIdNewName = T.pack $ T.unpack (ProcId.name procIdInst) ++ "$op" ++ show opNr
                  procIdNew = procIdInst { ProcId.name = procIdNewName,
                                            ProcId.unid = unid}
                  procDefNew = ProcDef chansDef paramsDef operand
                  procDefs' = Map.insert procIdNew procDefNew procDefs

                  procInst' = procInst procIdNew chansDef (map cstrVar paramsDef)
              return (procInst', procDefs')



-- ----------------------------------------------------------------------------------------- --
-- LPEHide :
-- ----------------------------------------------------------------------------------------- --

-- we assume that the top-level bexpr of the called ProcDef is HIDE
lpeHide :: (EnvB.EnvB envb) => BExpr -> TranslatedProcDefs -> ProcDefs -> envb(BExpr, ProcDefs)
lpeHide procInst@(TxsDefs.view -> ProcInst procIdInst chansInst paramsInst) translatedProcDefs procDefs = do
    let -- 
        ProcDef chansDef paramsDef bexpr = fromMaybe (error "lpePar: could not find the given procId") (Map.lookup procIdInst procDefs)
        Hide hiddenChans bexpr' = TxsDefs.view bexpr
        
        -- translate bexpr of HIDE to LPE first
        -- reuse current ProcDef: strip the HIDE operator, just leave the bexpr
        procDef' = ProcDef chansDef paramsDef bexpr'
        procDefs' = Map.insert procIdInst procDef' procDefs
    (procInst_lpe@(TxsDefs.view -> ProcInst procId_lpe chansInst_lpe paramsInst_lpe), procDefs'') <- lpe procInst translatedProcDefs procDefs'

    
        
    let -- decompose translated ProcDef
        ProcDef chansDef_lpe paramsDef_lpe bexpr_lpe = fromMaybe (error "lpeHide: could not find the given procId") (Map.lookup procId_lpe procDefs'')
        -- strip hidden chans and update ProcDef
        steps = extractSteps bexpr_lpe
        steps' = map (hideChans hiddenChans) steps
        procDef_lpe = trace ("\nlpeHide: steps: " ++ show steps') $ ProcDef chansDef_lpe paramsDef_lpe (wrapSteps steps')
        procDefs''' = Map.insert procId_lpe procDef_lpe procDefs''
    trace ("\n\nprocDefs: " ++ show procDefs''') $ return $ (procInst_lpe, procDefs''')
    where
        hideChans :: [ChanId] -> BExpr -> BExpr
        hideChans _ (TxsDefs.view -> Stop) = stop
        -- hideChans _ (ActionPref chanIdExit ) ??
        hideChans hiddenChans (TxsDefs.view -> ActionPref actOffer bexpr) = 
            let os = offers actOffer 
                os' = hideChansOffer (Set.toList os) 
            in trace ("\nhideChans: offer: " ++ show os') $ actionPref actOffer{ offers = Set.fromList os'} bexpr 
            where
                hideChansOffer :: [Offer] -> [Offer]
                hideChansOffer [] = []
                hideChansOffer (o:os) = 
                    let -- recursion 
                        os' = hideChansOffer os 
                        -- current case
                        chanid' = if (chanid o) `elem` hiddenChans 
                                    then chanIdIstep  
                                    else (chanid o)
                        o' = o{ chanid = chanid' }
                    in (o':os')

lpeHide _ _ _ = error "lpeHide: was called with something other than a ProcInst"
    
-- ----------------------------------------------------------------------------------------- --
-- LPE :
-- ----------------------------------------------------------------------------------------- --


-- | wrapper around lpe function, returning only the relevant ProcDef instead of all ProcDefs
lpeTransform :: (EnvB.EnvB envb )    --   Monad for unique identifiers and error messages
             => BExpr                -- ^ behaviour expression to be transformed,
                                     --   assumed to be a process instantiation
             -> ProcDefs             -- ^ context of process definitions in which process
                                     --   instantiation is assumed to be defined
             -> envb (Maybe (BExpr, ProcDef))
                                     -- ^ transformed process instantiation with LPE definition
-- template function for lpe
lpeTransform procInst procDefs  =
     case TxsDefs.view procInst of
       ProcInst procid@(ProcId nm uid chids vars ext) chans vexps
         -> case Map.lookup procid procDefs of
              Just procdef
                ->
                      lpeTransform' procInst procDefs
              _ -> do EnvB.putMsgs [ EnvData.TXS_CORE_USER_ERROR
                                     "LPE Transformation: undefined process instantiation" ]
                      return Nothing
       _ -> do EnvB.putMsgs [ EnvData.TXS_CORE_USER_ERROR
                              "LPE Transformation: only defined for process instantiation" ]
               return Nothing


-- carsten original function for lpe
lpeTransform' :: (EnvB.EnvB envb )   -- Monad for unique identifiers and error messages
             => BExpr                -- ^ behaviour expression to be transformed,
                                     --   assumed to be a process instantiation
             -> ProcDefs             -- ^ context of process definitions in which process
                                     --   instantiation is assumed to be defined
             -> envb (Maybe (BExpr, ProcDef))
lpeTransform' procInst''' procDefs = 
                                  do  -- create mapping for channel offer substitution
                                      -- decompose ProcDef, get channels
                                      --    DO NOT use ProcInst's channels: we don't want to instantiate that top-level ProcInst! 
                                      --    (and channels of ProcDef can be different)
                                      let   ProcInst procIdInst _ _ = TxsDefs.view procInst'''
                                            ProcDef chansOriginal _ _ =  fromMaybe (error "lpeTransform: could not find the given procId") (Map.lookup procIdInst procDefs)
                                      -- create numbered channeloffer list like below
                                      chanoffers_list <- mapM collectChanOffers chansOriginal
                                      let chanoffers_map = Map.fromList $ concat chanoffers_list
                                      -- add to monad
                                      EnvB.setChanoffers chanoffers_map
                                      mapping <- EnvB.getChanoffers 


                                      -- translate to LPE
                                      (procInst', procDefs') <- lpe procInst''' emptyTranslatedProcDefs procDefs
                                      procIdInstUid <- EnvB.newUnid
                                      let ProcInst procIdInst chansInst paramsInst = TxsDefs.view procInst'
                                          ProcDef chans params bexpr = fromMaybe (error "lpeTransform: could not find the given procId") (Map.lookup procIdInst procDefs')

                                          -- rename ProcId P to LPE_<P>
                                          -- put new ProcId in the procInst
                                          procIdName' = T.pack $ "LPE_" ++ T.unpack (ProcId.name procIdInst)
                                          procIdInst' = procIdInst { ProcId.name = procIdName',
                                                                     ProcId.unid = procIdInstUid}
                                          procInst'' = procInst procIdInst' chansInst paramsInst

                                          -- put new ProcId in each step
                                          steps = map (substituteProcId procIdInst procIdInst') (extractSteps bexpr)
                                          procDef = ProcDef chans params (wrapSteps steps) in
                                       -- trace (show procDef) $
                                       return $ Just (procInst'', procDef)
    where
        -- create new channoffers for ONE channel
        collectChanOffers :: (EnvB.EnvB envb ) => ChanId -> envb [((Name, Int), VarId)]
        collectChanOffers chanId = do   let list = zip [1..] (ChanId.chansorts chanId)
                                        varIds <- mapM (createVarId (ChanId.name chanId)) list
                                        return $ varIds
            where
                createVarId :: (EnvB.EnvB envb ) => Name -> (Int, SortId) -> envb ((Name, Int), VarId)
                createVarId chanName (varNr, varSort) = do  let chanName' = (T.unpack chanName) ++ "$" ++ show varNr
                                                            unid <- EnvB.newUnid 
                                                            return $ ((chanName, varNr), (VarId (T.pack chanName') unid varSort))

        substituteProcId :: ProcId -> ProcId -> BExpr -> BExpr
        substituteProcId orig new (TxsDefs.view -> Stop) = stop
        substituteProcId orig new (TxsDefs.view -> ActionPref actOffer (TxsDefs.view -> ProcInst procId chansInst paramsInst)) =
          if procId == orig
              then actionPref actOffer (procInst new chansInst paramsInst)
              else error "Found a different ProcId, thus the given BExpr is probably not in LPE format"

lpe :: (EnvB.EnvB envb ) => BExpr -> TranslatedProcDefs -> ProcDefs -> envb (BExpr, ProcDefs)
lpe procInst'@(TxsDefs.view -> ProcInst procIdInst chansInst paramsInst) translatedProcDefs procDefs = do
      -- remember the current ProcId to avoid recursive loops translating the same ProcId again
      let translatedProcDefs' = translatedProcDefs { lLPE = lLPE translatedProcDefs ++ [procIdInst]}

      -- first translate to GNF
      procDefs' <- gnf procIdInst translatedProcDefs' procDefs

      -- decompose translated ProcDef
      let ProcDef chansDef paramsDef bexpr = fromMaybe (error "LPE: could not find given procId (should be impossible)") (Map.lookup procIdInst procDefs')

      let accuInit = [(procIdInst, chansDef)]
      let calledProcs = calledProcDefs procDefs' accuInit (extractSteps bexpr)

      -- create program counter mapping
      pcUnid <- EnvB.newUnid
      let pcName = "pc$" ++ T.unpack (ProcId.name procIdInst)
      let varIdPC = VarId (T.pack pcName) pcUnid intSort
      let pcMapping = Map.fromList $ zip calledProcs [0..]

      (steps, params, procToParams) <- translateProcs calledProcs varIdPC pcMapping procDefs'


      -- create the new ProcId, ProcInst, ProcDef
      procIdUnid <- EnvB.newUnid
      let nameNew = T.unpack (ProcId.name procIdInst)
          paramsNew = varIdPC : params
          procIdNew = procIdInst { ProcId.name = T.pack nameNew
                                   , ProcId.unid = procIdUnid
                                   , ProcId.procchans = chansDef
                                   , ProcId.procvars = paramsNew}

          -- update the ProcInsts in the steps
          steps' = map (stepsUpdateProcInsts calledProcs procToParams pcMapping procIdNew) steps

          procDefLpe = ProcDef chansDef paramsNew (wrapSteps steps')
          procDefs'' = Map.insert procIdNew procDefLpe procDefs'
          -- update the ProcInst to the new ProcDef
          procInstLPE = updateProcInst procInst' procIdNew calledProcs

      return (procInstLPE, procDefs'')

    where
        -- recursively collect all (ProcId, Channels)-combinations that are called
        calledProcDefs :: ProcDefs -> [Proc] -> [BExpr] -> [Proc]
        calledProcDefs procDefs = foldl (processStep procDefs)
          where
            processStep :: ProcDefs -> [Proc] -> BExpr -> [Proc]
            -- case bexpr == A >-> P'[]()
            processStep procDefs accu (TxsDefs.view -> ActionPref actOffer procInst@(TxsDefs.view -> ProcInst procIdInst chansInst paramsInst)) =
              if (procIdInst, chansInst) `elem` accu
                then accu
                else let -- add combination to accu
                         accu' = accu ++ [(procIdInst, chansInst)]
                         -- decompose ProcDef
                         ProcDef chansDef paramsDef bexprDef = fromMaybe (error "LPE: could not find given procId (should be impossible)") (Map.lookup procIdInst procDefs)
                         -- instantiate bexpr with channels of ProcInst
                         chanmap = Map.fromList (zip chansDef chansInst)
                         bexprRelabeled = relabel chanmap bexprDef
                         -- go through steps recursively
                         accu'' = calledProcDefs procDefs accu' (extractSteps bexprRelabeled) in
                     accu''

            -- case bexpr == A >-> STOP: nothing to collect
            processStep procDefs proc bexpr = proc

        -- translate all Procs (procId, channels)-combination
        translateProcs :: (EnvB.EnvB envb ) => [Proc] -> VarId -> PCMapping -> ProcDefs -> envb ([BExpr], [VarId], ProcToParams)
        translateProcs [] _ _ _ = return ([], [], Map.fromList [])
        translateProcs (currentProc@(procId, chans):procss) varIdPC pcMapping procDefs = do
            let   -- decompose translated ProcDef
                  ProcDef chansDef paramsDef bexprDef = fromMaybe (error $ "\ntranslateProcs: could not find given procId (should be impossible)" ++ show procId ++
                                             "\nprocDefs: " ++ show procDefs) (Map.lookup procId procDefs)
                  steps = extractSteps bexprDef

                  -- prepare channel instantiation
                  chanMap = Map.fromList (zip chansDef chans)
                  -- prepare param renaming (uniqueness)
                  chanNames = map (\chanId -> "$" ++ T.unpack (ChanId.name chanId) ) chans
                  prefix = T.unpack (ProcId.name procId) ++ concat chanNames ++ "$"

            -- prefix the params and wrap them as VExpr just to be able to use the substitution function later
            prefixedParams' <- mapM (prefixVarId prefix) paramsDef
            let prefixedParams = map cstrVar prefixedParams'
                paramMap = Map.fromList $ zip paramsDef prefixedParams

            let pcValue = fromMaybe (error "translateProcs: could not find the pcValue for given proc (should be impossible)") (Map.lookup currentProc pcMapping)

            -- let steps' = map (lpeBExpr chanMap paramMap varIdPC pcValue) steps
            steps' <- mapM (lpeBExpr chanMap paramMap varIdPC pcValue) steps
            let steps'' = filter (not . (\b -> TxsDefs.view b == Stop)) steps'       -- filter out the Stops
            -- recursion
            (stepsRec, paramsRec, procToParamsRec) <- translateProcs procss varIdPC pcMapping procDefs

            -- add collected prefixed params for later usage
            let params = prefixedParams' ++ paramsRec
            let procToParams = Map.insert currentProc prefixedParams' procToParamsRec
            return (steps'' ++ stepsRec, params, procToParams)

        -- update the original ProcInst, initialise with artifical values
        updateProcInst :: BExpr -> ProcId -> [Proc] -> BExpr
        updateProcInst (TxsDefs.view -> ProcInst procIdInst chansInst paramsInst) procIdNew calledProcs =
            let pcValue = cstrConst (Cint 0)
                -- get the params, but leave out the first ones (those of procIdInst itself)
                -- plus an extra one (that of the program counter)
                params = snd $ splitAt (length paramsInst+1) (ProcId.procvars procIdNew)
                paramsSorts = map varIdToSort params
                paramsANYs = map (cstrConst . Cany) paramsSorts
                paramsNew = (pcValue : paramsInst) ++ paramsANYs in
            procInst procIdNew chansInst paramsNew

        -- update the ProcInsts in the steps to the new ProcId
        stepsUpdateProcInsts :: [Proc] -> ProcToParams -> PCMapping -> ProcId -> BExpr -> BExpr
        stepsUpdateProcInsts procs procToParams pcMap procIdNew (TxsDefs.view -> ActionPref actOffer (TxsDefs.view -> Stop)) =
            let -- get the params, but leave out the first one because it's the program counter
                (_:params) = ProcId.procvars procIdNew
                paramsSorts = map varIdToSort params
                paramsANYs = map (cstrConst . Cany) paramsSorts
                paramsInst = (cstrConst (Cint (-1)) : paramsANYs)
                chansInst = ProcId.procchans procIdNew
                procInst' = procInst procIdNew chansInst paramsInst in
            actionPref actOffer procInst'

        stepsUpdateProcInsts procs procToParams pcMap procIdNew bexpr@(TxsDefs.view -> ActionPref actOffer procInst''@(TxsDefs.view -> ProcInst procIdInst chansInst paramsInst)) =
            let -- collect params AND channels from procs in the order they appear in procs
                paramsNew = createParams procs procInst''

                pcValue = fromMaybe (error "stepsUpdateProcInsts: no pc value found for given (ProcId, [ChanId]) (should be impossible)") (Map.lookup (procIdInst, chansInst) pcMap)

                procInst' = procInst procIdNew (ProcId.procchans procIdNew) ( cstrConst (Cint pcValue) : paramsNew) in
            actionPref actOffer procInst'
            where
                createParams :: [Proc] -> BExpr -> [VExpr]
                createParams [] _ = []
                createParams (proc@(procId, procChans):procs) procInst''@(TxsDefs.view -> ProcInst procIdInst chansInst paramsInst) =
                    let paramsRec = createParams procs procInst''
                        params = if (procId, procChans) == (procIdInst, chansInst)
                                    then paramsInst
                                    else case Map.lookup proc procToParams of
                                             Just ps   -> map cstrVar ps
                                             Nothing   -> error "createParams: no params found for given proc (should be impossible)"
                    in
                    params ++ paramsRec

        stepsUpdateProcInsts _ _ _ _ bexpr = bexpr


        varIdToSort :: VarId -> SortId
        varIdToSort (VarId _ _ sort) = sort


        prefixVarId ::  (EnvB.EnvB envb ) => String -> VarId -> envb VarId
        prefixVarId prefix (VarId name _ sort) = do
            unid <- EnvB.newUnid
            let name' = T.pack $ prefix ++ T.unpack name
            return $ VarId name' unid sort


lpeBExpr :: (EnvB.EnvB envb ) => ChanMapping -> ParamMapping -> VarId -> Integer -> BExpr -> envb BExpr
lpeBExpr chanMap paramMap varIdPC pcValue (TxsDefs.view -> Stop) = return stop
lpeBExpr chanMap paramMap varIdPC pcValue bexpr = do
    let -- instantiate the bexpr
        bexprRelabeled = relabel chanMap bexpr
        -- TODO: properly initialise funcDefs param of subst
        bexprSubstituted = Subst.subst paramMap (Map.fromList []) bexprRelabeled

        -- decompose bexpr, bexpr' can be STOP or ProcInst (distinction later)
        ActionPref actOffer bexpr' = TxsDefs.view bexprSubstituted


    (offers', constraints', varMap) <- translateOffers (Set.toList (offers actOffer))


    let -- constraints of offer need to be substituted:
        -- say A?x [x>1], this becomes A?A1 [A1 > 1]
        constraintOfOffer = constraint actOffer
        varMap' = Map.fromList $ map (Control.Arrow.second cstrVar) varMap

        -- TODO: properly initialise funcDefs param of subst
        constraintOfOffer' = Subst.subst varMap' (Map.fromList []) constraintOfOffer
        constraintsList = constraintOfOffer' : constraints'
        constraintPC = cstrEqual (cstrVar varIdPC) (cstrConst (Cint pcValue))


        -- if there is a constraint other than just the program counter check
        --    i.e. the normal constraint is empty (just True)
        -- then evaluate the program counter constraint first in an IF clause
        --    to avoid evaluation of possible comparisons with ANY in the following constraint
        constraint' = if constraintsList == [cstrConst (Cbool True)]
                        then constraintPC
                        else cstrITE constraintPC (cstrAnd (Set.fromList constraintsList)) (cstrConst (Cbool False))

        actOffer' = ActOffer { offers = Set.fromList offers'
                             , constraint = constraint' }

        bexpr'' = case TxsDefs.view bexpr' of
                    Stop -> stop
                    -- TODO: properly initialise funcDefs param of subst
                    _    -> Subst.subst varMap' (Map.fromList []) bexpr'
    return (actionPref actOffer' bexpr'')

    where
        -- transform actions: e.g. A?x [x == 1] becomes A?A1 [A1 == 1]
        translateOffers :: (EnvB.EnvB envb ) => [Offer] -> envb ([Offer], [VExpr], [(VarId, VarId)])
        translateOffers [] = return ([], [], [])
        translateOffers (offer:offers) = do
            let chanId = chanid offer
                chanOffers = chanoffers offer

                chanOffersNumberedSorts = zip3 [1..] chanOffers (ChanId.chansorts chanId)
                chanName = ChanId.name chanId

            (chanOffers', constraints, varMap) <- translateChanOffers chanOffersNumberedSorts chanName

            let offer' = offer { chanoffers = chanOffers'}
            (offersRec, constraintsRec, varMapRec) <- translateOffers offers

            return (offer':offersRec, constraints ++ constraintsRec, varMap ++ varMapRec)
            where
                translateChanOffers :: (EnvB.EnvB envb ) => [(Int, ChanOffer, SortId)] -> Name -> envb ([ChanOffer], [VExpr], [(VarId, VarId)])
                translateChanOffers [] _ = return ([], [], [])
                translateChanOffers ((i, chanOffer, sort) : chanOffers) chanName = do
                    -- recursion first
                    (chanOffersRec, constraintsRec, varMapRec) <- translateChanOffers chanOffers chanName
                    -- transform current chanOffer

                    -- redo next 3 lines
                    -- just need to lookup the right varId in monad
                    mapping <- EnvB.getChanoffers 
                    -- let chanName' = trace ("mapping: " ++ (show mapping)) $ chanName ++ "$" ++ show i
                    -- unid <- EnvB.newUnid

                    -- let varIdChani = VarId (T.pack chanName') unid sort
                    let varIdChani = case (Map.lookup (chanName, i) mapping) of
                                        Just varId  -> varId
                                        _           -> error "translateChanOffers: chanoffer not found "
                        chanOffer' = Quest varIdChani
                        constraints = case chanOffer of
                                        (Quest varId)  -> constraintsRec
                                        (Exclam vexpr) -> let constraint' = cstrEqual (cstrVar varIdChani) vexpr in
                                                                (constraint':constraintsRec)
                        varMap = case chanOffer of
                                        (Quest varId)   -> (varId, varIdChani) : varMapRec
                                        (Exclam vexpr)  -> varMapRec
                    return (chanOffer':chanOffersRec, constraints, varMap)

-- ----------------------------------------------------------------------------------------- --
--                                                                                           --
-- ----------------------------------------------------------------------------------------- --
