{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Cubix.Language.C.Parametric.Common.Cfg () where

#ifndef ONLY_ONE_LANGUAGE
import Control.Monad ( liftM, liftM2, forM_ )
import Control.Monad.State ( State, MonadState )

import Control.Lens ( makeLenses, (%=), (.=), use )

import Data.Foldable ( foldlM )
import Data.List as List ( (\\) )
import Data.Map as Map ( empty )

import Data.Comp.Multi ( stripA, remA, (:*:)(..), ffst, project, proj, E(..), (:&:)(..), subterms, (:-<:), Cxt (..) )

import Cubix.Language.Info

import Cubix.Language.C.Parametric.Common.Types as C
import Cubix.Language.C.Parametric.Full.Types as F
import Cubix.Language.Parametric.InjF
import Cubix.Language.Parametric.Semantics.Cfg
import Cubix.Language.Parametric.Syntax as P

data CCfgState = CCfgState {
                   _ccs_cfg       :: Cfg MCSig
                 , _ccs_labeler   :: LabelGen
                 , _ccs_stack     :: LoopStack
                 , _ccs_goto_labs :: LabelMap
                 }

makeLenses ''CCfgState

instance HasCurCfg CCfgState MCSig where cur_cfg = ccs_cfg
instance HasLabelGen CCfgState where labelGen = ccs_labeler
instance HasLoopStack CCfgState where loopStack = ccs_stack
instance HasLabelMap CCfgState where labelMap = ccs_goto_labs


type instance ComputationSorts MCSig = '[CStatementL, CExpressionL, CCompoundBlockItemL, [BlockItemL]]
type instance SuspendedComputationSorts MCSig = '[FunctionDefL]
type instance ContainerFunctors MCSig = '[PairF, TripleF, ListF, MaybeF, EitherF]
type instance CfgState MCSig = CCfgState

nameString :: MCTermLab F.IdentL -> String
nameString (stripA -> projF -> Just (Ident' n)) = n

singleton :: a -> [a]
singleton = return

extractForInit :: (HasCurCfg s MCSig) => HState s (EnterExitPair MCSig) (Either (Maybe CExpressionL) CDeclarationL) -> State s (Maybe (EnterExitPair MCSig ()))
extractForInit m = do
  p1' <- unHState m
  let SubPairs p1 = p1'
  case kextractF2' p1 of
    Left x  -> mapM collapseEnterExit =<< (extractEEPMaybe $ return x)
    Right x -> Just <$> collapseEnterExit x


-- TODO: test this for Duff's device (once we have switches working)
instance ConstructCfg MCSig CCfgState CStatement where
  constructCfg t@(remA -> CLabel (nam :*: _) (_ :*: mStatEE) _ _) = HState $ do
    -- It's easiest to model it as if the label and the ensuing statement are separate
   labEE <- constructCfgLabel (ffst $ collapseFProd' t) (nameString nam)
   statEE <- unHState mStatEE
   combineEnterExit labEE statEE

  constructCfg (collapseFProd' -> (t :*: (CIf e thn optElse _))) = HState $ constructCfgIfElseIfElse t (liftM singleton $ liftM2 (,) (unHState e) (unHState thn)) (extractEEPMaybe $ unHState optElse)
  constructCfg (collapseFProd' -> (t :*: (CWhile e b False _))) = HState $ constructCfgWhile   t (unHState e) (unHState b)
  constructCfg (collapseFProd' -> (t :*: (CWhile e b True _)))  = HState $ constructCfgDoWhile t (unHState e) (unHState b)

  constructCfg t@(remA -> CGoto (nam :*: _) _) = HState $ constructCfgGoto (ffst $ collapseFProd' t) (nameString nam)
  constructCfg (collapseFProd' -> (t :*: (CGotoPtr e _))) = HState $ constructCfgReturn t (liftM Just $ unHState e)
  constructCfg (collapseFProd' -> (t :*: (CCont _))) = HState $ constructCfgContinue t
  constructCfg (collapseFProd' -> (t :*: (CBreak _))) = HState $ constructCfgBreak t
  constructCfg (collapseFProd' -> (t :*: (CReturn e _))) = HState $ constructCfgReturn t (extractEEPMaybe $ unHState e)

  constructCfg (collapseFProd' -> (t :*: (CFor init cond step body _))) = HState $ constructCfgFor t (extractForInit init) (extractEEPMaybe $ unHState cond) (extractEEPMaybe $ unHState step) (unHState body)

  constructCfg (collapseFProd' -> (t :*: (CSwitch exp body _))) = HState $ do
    enterNode <- addCfgNode t EnterNode
    exitNode  <- addCfgNode t ExitNode

    expEE <- unHState exp

    pushBreakNode exitNode
    bodyEE <- unHState body
    popBreakNode

    cur_cfg %= addEdge enterNode (enter expEE)
    cur_cfg %= addEdge (exit expEE) (enter bodyEE)
    cur_cfg %= addEdge (exit bodyEE) exitNode

    forM_ cases $ \(E case0) -> do
      ccfg <- use cur_cfg
      let Just enCase = cfgNodeForTerm ccfg EnterNode case0
      cur_cfg %= addEdge (exit expEE) enCase

    return $ EnterExitPair enterNode exitNode

      where cases = case project0 t of
              Just (remA -> CSwitch _ b0 _) -> extractCases b0

            extractCases t0 =
              let subs = subterms t0
                  cases0 = filter isCase subs
                  switches = filter isSwitch subs
                  subcases = filter isCase (concatMap (\(E e0) -> subterms e0) switches)
              in  cases0 List.\\ subcases

            isCase :: E MCTermLab -> Bool
            isCase (E (project0 -> Just (remA -> CCase {}))) = True
            isCase (E (project0 -> Just (remA -> CDefault {}))) = True
            isCase _ = False

            isSwitch :: E MCTermLab -> Bool
            isSwitch (E (project0 -> Just (remA -> CSwitch {}))) = True
            isSwitch _ = False

            project0 :: (f :-<: MCSig) => MCTermLab l -> Maybe ((f :&: Label) MCTermLab l)
            project0 (Term (s :&: l)) = fmap (:&: l) (proj s)

  constructCfg t = constructCfgDefault t

instance ConstructCfg MCSig CCfgState CExpression where
  constructCfg t'@(remA -> (CBinary (op :*: _) _ _ _)) = do
    let (t :*: (CBinary _ el er _)) = collapseFProd' t'
    case extractOp op of
      CLndOp -> HState $ constructCfgShortCircuitingBinOp t (unHState el) (unHState er)
      CLorOp  -> HState $ constructCfgShortCircuitingBinOp t (unHState el) (unHState er)
      _   -> constructCfgDefault t'

    where extractOp :: MCTermLab CBinaryOpL -> CBinaryOp MCTerm CBinaryOpL
          extractOp (stripA -> project -> Just bp) = bp

  constructCfg t'@(remA -> CCond {}) = HState $ do
    let (t :*: (CCond test succ fail _)) = collapseFProd' t'
    constructCfgCCondOp t (unHState test) (extractEEPMaybe (unHState succ)) (unHState fail)

  constructCfg t = constructCfgDefault t

-- NOTE: because of gcc extension which allows things like x ? : y
constructCfgCCondOp ::
  ( MonadState s m
  , CfgComponent MCSig s
  ) => TermLab MCSig l -> m (EnterExitPair MCSig ls) -> m (Maybe (EnterExitPair MCSig rs)) -> m (EnterExitPair MCSig es) -> m (EnterExitPair MCSig es)
constructCfgCCondOp t mtest msucc mfail = do
  enterNode <- addCfgNode t EnterNode
  exitNode  <- addCfgNode t ExitNode

  test <- mtest
  fail <- mfail
  succ <- msucc

  case succ of
    Just succ0 -> do
      cur_cfg %= addEdge enterNode (enter test)
      cur_cfg %= addEdge (exit test) (enter succ0)
      cur_cfg %= addEdge (exit test) (enter fail)
      cur_cfg %= addEdge (exit succ0) exitNode
      cur_cfg %= addEdge (exit fail) exitNode
    Nothing -> do
      cur_cfg %= addEdge enterNode (enter test)
      cur_cfg %= addEdge (exit test) (enter fail)
      cur_cfg %= addEdge (exit test) exitNode
      cur_cfg %= addEdge (exit fail) exitNode

  return (EnterExitPair enterNode exitNode)

-- CLabelBlock's getting nodes is messing everything up
instance ConstructCfg MCSig CCfgState CLabeledBlock where
  constructCfg (collapseFProd' -> (_ :*: subCfgs)) = HState $ runSubCfgs subCfgs

instance ConstructCfg MCSig CCfgState P.FunctionDef where
  constructCfg (collapseFProd' -> (_ :*: subCfgs)) = HState $ do
    -- reset label map on function entry
    label_map .= Map.empty
    runSubCfgs subCfgs
    pure EmptyEnterExit

instance CfgInitState MCSig where
  cfgInitState _ = CCfgState emptyCfg (unsafeMkCSLabelGen ()) emptyLoopStack emptyLabelMap
#endif
