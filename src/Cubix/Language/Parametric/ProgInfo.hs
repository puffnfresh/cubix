{-# LANGUAGE FlexibleContexts         #-}
{-# LANGUAGE FlexibleInstances        #-}
{-# LANGUAGE FunctionalDependencies   #-}
{-# LANGUAGE MultiParamTypeClasses    #-}
{-# LANGUAGE TemplateHaskell          #-}

module Cubix.Language.Parametric.ProgInfo (
    ProgInfo
  , HasProgInfo(..)

  , makeProgInfo
  , cfgNodePath
  , labToPath
  ) where

import Control.Lens ( makeClassy, (^.))
import Data.Map ( Map )
import qualified Data.Map as Map

import Data.Comp.Multi ( runE, All, HFoldable)

import Cubix.Language.Info
import Cubix.Language.Parametric.Path
import Cubix.Language.Parametric.Semantics.Cfg

import Cubix.Sin.Compdata.Annotation ( getAnn )


data ProgInfo fs = ProgInfo { _proginf_cfg :: Cfg fs
                            , _proginf_paths :: Map Label Path
                            }

makeClassy ''ProgInfo

makeProgInfo :: (CfgBuilder fs, All HFoldable fs) => TermLab fs l -> ProgInfo fs
makeProgInfo t = ProgInfo (makeCfg t) (getPaths t)

cfgNodePath :: ProgInfo fs -> CfgNode fs -> Maybe Path
cfgNodePath progInf n = Map.lookup termLab (progInf ^. proginf_paths)
  where
    termLab = runE getAnn (n ^. cfg_node_term)



labToPath :: Label -> ProgInfo fs -> Path
labToPath l progInf = let paths = progInf ^. proginf_paths in
                      case Map.lookup l paths of
                        Just p  -> p
                        Nothing -> error $ "No path for label: " ++ show l
