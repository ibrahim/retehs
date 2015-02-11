{-# LANGUAGE    Trustworthy           #-}
{-# LANGUAGE    TypeSynonymInstances  #-}
{-# LANGUAGE    FlexibleInstances     #-}
{-# LANGUAGE    MultiParamTypeClasses #-}
{-# LANGUAGE    RankNTypes            #-}
{-# OPTIONS_GHC -W -Wall              #-}
------------------------------------------------------------------------
-- |
-- Module      : AI.Rete.Print
-- Copyright   : (c) 2014 Konrad Grzanek
-- License     : BSD-style (see the file LICENSE)
-- Created     : 2014-11-14
-- Reworked    : 2015-02-09
-- Maintainer  : kongra@gmail.com
-- Stability   : experimental
-- Portability : requires stm
--
-- Textual visualization of Rete network and data.
------------------------------------------------------------------------
module AI.Rete.Print where

import           AI.Rete.Data
import           Control.Concurrent.STM
import           Control.Monad (liftM)
import           Data.Foldable (Foldable)
import qualified Data.HashSet as Set
import           Data.Hashable (Hashable, hashWithSalt)
import           Data.Tree.Print
import           Kask.Control.Monad (toListM)
import           Kask.Data.Function (compose)

--
-- import qualified Data.HashMap.Strict as Map
-- import           Data.List (intersperse)
-- import           Data.Maybe (catMaybes, fromJust)
-- import           Data.Tree.Print
-- import           Kask.Control.Monad (toListM, mapMM)

-- CONFIGURATION

-- | A Boolean (semanticaly) configuration option for the printing
-- process.
data Flag =
  -- Emph flag
  NetEmph | DataEmph

  -- Wme flags
  | WmeIds | WmeSymbolic | WmeAmems | WmeToks | WmeNegJoinResults

  -- Token flags
  | TokIds      | TokWmes           | TokWmesSymbolic | TokNodes | TokParents
  | TokChildren | TokNegJoinResults

  -- Amem flags
  | AmemFields | AmemRefCounts | AmemWmes | AmemSuccessors

  -- Node flags
  | NodeIds | NodeParents | NodeChildren

  -- Unlinking flags
  | Uls

  -- Bmem flags
  | BmemToks

  -- JoinNode flags
  | JoinTests  | JoinAmems | JoinNearestAncestors

  -- NegNode flags
  | NegTests   | NegAmems  | NegNearestAncestors | NegToks

  -- Prod flags
  | ProdBindings | ProdToks deriving (Show, Eq)

flagCode :: Flag -> Int
flagCode NetEmph              = 0
flagCode DataEmph             = 1
flagCode WmeIds               = 2
flagCode WmeSymbolic          = 3
flagCode WmeAmems             = 4
flagCode WmeToks              = 5
flagCode WmeNegJoinResults    = 6
flagCode TokIds               = 7
flagCode TokWmes              = 8
flagCode TokWmesSymbolic      = 9
flagCode TokNodes             = 10
flagCode TokParents           = 11
flagCode TokChildren          = 12
flagCode TokNegJoinResults    = 13
flagCode AmemFields           = 14
flagCode AmemRefCounts        = 15
flagCode AmemWmes             = 16
flagCode AmemSuccessors       = 17
flagCode NodeIds              = 18
flagCode NodeParents          = 19
flagCode NodeChildren         = 20
flagCode Uls                  = 21
flagCode BmemToks             = 22
flagCode JoinTests            = 23
flagCode JoinAmems            = 24
flagCode JoinNearestAncestors = 25
flagCode NegTests             = 26
flagCode NegAmems             = 27
flagCode NegNearestAncestors  = 28
flagCode NegToks              = 29
flagCode ProdBindings         = 30
flagCode ProdToks             = 31
{-# INLINE flagCode #-}

instance Hashable Flag where
  hashWithSalt salt flag = salt `hashWithSalt` flagCode flag

-- | A set of 'Flags's.
type Flags = Set.HashSet Flag

-- | A switch to turn the 'Flag's on/off.
type Switch = Flags -> Flags

-- | Creates a 'Switch' that turns the 'Flag' on.
with :: Flag -> Switch
with = Set.insert
{-# INLINE with #-}

-- | Creates a 'Switch' that turns the 'Flag' off.
no :: Flag -> Switch
no = Set.delete
{-# INLINE no #-}

-- | Creates a 'Switch' that turns all flags off.
clear :: Switch
clear _ = noFlags

-- | Asks whether the 'Flag' is on in 'Flags'.
is :: Flag -> Flags -> Bool
is = Set.member
{-# INLINE is #-}

-- | A set of 'Flag's with all 'Flag's turned off.
noFlags :: Flags
noFlags = Set.empty

-- PREDEFINED Switch CONFIGURATIONS

dataFlags :: [Flag]
dataFlags =  [ WmeToks
             , WmeNegJoinResults
             , TokWmes
             , TokParents
             , TokChildren
             , TokNegJoinResults
             , AmemWmes
             , BmemToks
             , NegToks
             , ProdToks ]

netFlags :: [Flag]
netFlags =  [ WmeAmems
            , TokNodes
            , AmemRefCounts
            , AmemSuccessors
            , NodeParents
            , NodeChildren
            , JoinTests
            , JoinAmems
            , JoinNearestAncestors
            , NegTests
            , NegAmems
            , NegNearestAncestors
            , ProdBindings ]

idFlags :: [Flag]
idFlags =  [WmeIds, TokIds, NodeIds]

-- | A 'Switch' that turns data presentation off.
noData :: Switch
noData = compose (map no dataFlags)

-- | A 'Switch' that turns data presentation on.
withData :: Switch
withData = compose (map with dataFlags)

-- | A 'Switch' that turns network presentation off.
noNet :: Switch
noNet = compose (map no netFlags)

-- | A 'Switch' that turns network presentation on.
withNet :: Switch
withNet = compose (map with netFlags)

-- | A 'Switch' that imposes the presentation traversal from lower
-- nodes to higher.
up :: Switch
up = with NodeParents . no NodeChildren . no AmemSuccessors

-- | A 'Switch' that imposes the presentation traversal from higher
-- nodes to lower.
down :: Switch
down = with NodeChildren . no AmemSuccessors . no NodeParents

-- | A 'Switch' that turns IDs presentation off.
noIds :: Switch
noIds = compose (map no idFlags)

-- | A 'Switch' that turns Ids presentation on.
withIds :: Switch
withIds = compose (map with idFlags)

-- DEFENDING AGAINST CYCLES

data Visited = Visited { visitedWmes  :: !(Set.HashSet Wme )

                       , visitedBtoks :: !(Set.HashSet Btok)
                       , visitedNtoks :: !(Set.HashSet Ntok)
                       , visitedPtoks :: !(Set.HashSet Ptok)

                       , visitedAmems :: !(Set.HashSet Amem)

                       , visitedBmems :: !(Set.HashSet Bmem)
                       , visitedJoins :: !(Set.HashSet Join)
                       , visitedNegs  :: !(Set.HashSet Neg )
                       , visitedProds :: !(Set.HashSet Prod) }

cleanVisited :: Visited
cleanVisited =  Visited { visitedWmes  = Set.empty
                        , visitedBtoks = Set.empty
                        , visitedNtoks = Set.empty
                        , visitedPtoks = Set.empty
                        , visitedAmems = Set.empty
                        , visitedBmems = Set.empty
                        , visitedJoins = Set.empty
                        , visitedNegs  = Set.empty
                        , visitedProds = Set.empty }

class Visitable a where
  visiting :: a -> Visited -> Visited
  visited  :: a -> Visited -> Bool

instance Visitable Wme where
  visiting wme vs = vs { visitedWmes = Set.insert wme (visitedWmes vs) }
  visited  wme vs = Set.member wme (visitedWmes vs)
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable Btok where
  visiting btok vs = vs { visitedBtoks = Set.insert btok (visitedBtoks vs) }
  visited  btok vs = Set.member btok (visitedBtoks vs)
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable Ntok where
  visiting ntok vs = vs { visitedNtoks = Set.insert ntok (visitedNtoks vs) }
  visited  ntok vs = Set.member ntok (visitedNtoks vs)
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable Ptok where
  visiting ptok vs = vs { visitedPtoks = Set.insert ptok (visitedPtoks vs) }
  visited  ptok vs = Set.member ptok (visitedPtoks vs)
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable Amem where
  visiting amem vs = vs { visitedAmems = Set.insert amem (visitedAmems vs) }
  visited  amem vs = Set.member amem (visitedAmems vs)
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable Bmem where
  visiting bmem vs = vs { visitedBmems = Set.insert bmem (visitedBmems vs) }
  visited  bmem vs = Set.member bmem (visitedBmems vs)
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable Join where
  visiting join vs = vs { visitedJoins = Set.insert join (visitedJoins vs) }
  visited  join vs = Set.member join (visitedJoins vs)
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable Neg where
  visiting neg vs = vs { visitedNegs = Set.insert neg (visitedNegs vs) }
  visited  neg vs = Set.member neg (visitedNegs vs)
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable Prod where
  visiting prod vs = vs { visitedProds = Set.insert prod (visitedProds vs) }
  visited  prod vs = Set.member prod (visitedProds vs)
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable Location where
  visiting _ vs = vs  -- no need to ever mark Locations as visited
  visited  _ _  = False
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

instance Visitable JoinTest where
  visiting _ vs = vs  -- no need to ever mark JoinTest as visited
  visited  _ _  = False
  {-# INLINE visiting #-}
  {-# INLINE visited  #-}

withEllipsis :: Bool -> ShowS -> STM ShowS
withEllipsis False s = return s
withEllipsis True  s = return (compose [s, showString " ..."])
{-# INLINE withEllipsis #-}

withEllipsisT :: Bool -> STM ShowS -> STM ShowS
withEllipsisT v s = s >>= withEllipsis v
{-# INLINE withEllipsisT #-}

-- whenNot :: Bool -> STM [Vn] -> STM [Vn]
-- whenNot True  _   = return []
-- whenNot False vns = vns
-- {-# INLINE whenNot #-}

-- Vns (VISUALIZATION NODEs)

type VnShow = Flags -> Visited -> STM ShowS
type VnAdjs = Flags -> Visited -> STM [Vn]

-- | Represents types whose values are convertible to Vn.
class Vnable a where
  toVnShow :: a -> VnShow
  toVnAdjs :: a -> VnAdjs

-- | Visualization node.
data Vn = Vn { vnShowM   :: !VnShow
             , vnAdjs    :: !VnAdjs
             , vnVisited :: !Visited }

-- | Converts the passed object to a Vn.
toVn :: Vnable a => Visited -> a -> Vn
toVn vs x = Vn { vnShowM   = toVnShow x
               , vnAdjs    = toVnAdjs x
               , vnVisited = vs }
{-# INLINE toVn #-}

instance ShowM STM Flags Vn where
  showM flags Vn { vnShowM = f, vnVisited = vs } = f flags vs
  {-# INLINE showM #-}

-- SPECIFIC Vns

-- | Creates a Vn that has no adjs - thus is a leaf.
leafVn :: Visited -> VnShow -> Vn
leafVn vs show' = Vn { vnShowM   = show'
                     , vnAdjs    = \_ _ -> return []
                     , vnVisited = vs }
{-# INLINE leafVn #-}

-- | Creates a label Vn with passed adjs.
labelVn :: Visited -> ShowS -> [Vn] -> Vn
labelVn vs label adjs' = Vn { vnShowM   = \_ _ -> return label
                            , vnAdjs    = \_ _ -> return adjs'
                            , vnVisited = vs }
{-# INLINE labelVn #-}

-- | Creates a Vn that represents a label with a sequence of leaf
-- subnodes (Vns).
labeledLeavesVn :: Visited -> ShowS -> [VnShow] -> Vn
labeledLeavesVn vs label shows' = labelVn vs label (map (leafVn vs) shows')
{-# INLINE labeledLeavesVn #-}

-- | Generates a ShowS representation of an Id.
idS :: Id -> ShowS
idS id' = compose [showString " ", showString $ show id']
{-# INLINE idS #-}

-- | Composes the passed ShowS with a representation of the Id.
withIdS :: ShowS -> Id -> ShowS
withIdS s id' = compose [s, idS id']
{-# INLINE withIdS #-}

-- | Works like withIdS, but uses the Id representation optionally,
-- depending on the passed flag.
withOptIdS :: Bool -> ShowS -> Id -> ShowS
withOptIdS False s _   = s
withOptIdS True  s id' = s `withIdS` id'
{-# INLINE withOptIdS #-}

-- | Converts the monadic foldable into a sequence of Vns. All in the
-- m monad.
toVnsM :: (Monad m, Foldable f, Vnable a) => Visited -> m (f a) -> m [Vn]
toVnsM vs = liftM (map (toVn vs)) . toListM
{-# INLINE toVnsM #-}

-- | Works like toVnsM, but returns a list of VnShows instead of Vns.
toVnShowsM :: (Monad m, Foldable f, Vnable a) => m (f a) -> m [VnShow]
toVnShowsM = liftM (map toVnShow) . toListM
{-# INLINE toVnShowsM #-}

type OptLabelVn = (Monad m, Foldable f, Vnable a)
               => Bool -> String -> Visited -> m (f a) -> m (Maybe Vn)

optLabelVn :: OptLabelVn -- TODO: przemyśleć nazwy
optLabelVn False _     _  _  = return Nothing
optLabelVn True  label vs xs = do
  vns <- toVnsM vs xs
  if null vns
     then return Nothing
     else return (Just (labelVn vs (showString label) vns))

-- optLeafPropVn :: OptLabelVn
-- optLeafPropVn False _     _  _  = return Nothing
-- optLeafPropVn True  label vs xs = do
--   shows' <- toVnShowsM xs
--   if null shows'
--      then return Nothing
--      else return (Just (labeledLeavesVn vs (showString label) shows'))

-- optVns :: Monad m => [Maybe Vn] -> m [Vn]
-- optVns = return . catMaybes
-- {-# INLINE optVns #-}

-- netPropVn :: Flags -> OptLabelVn
-- netPropVn flags = if is NetEmph flags then optLabelVn else optLeafPropVn
-- {-# INLINE netPropVn #-}

-- datPropVn :: Flags -> OptLabelVn
-- datPropVn flags = if is DataEmph flags then optLabelVn else optLeafPropVn
-- {-# INLINE datPropVn #-}

-- -- CONFIGURATION

-- type VConf = Conf STM ShowS Flags Vn

-- conf :: VConf
-- conf = Conf { impl     = stmImpl
--             , adjs     = \fs Vn { vnAdjs = f, vnVisited = vs } -> f flags vs
--             , maxDepth = Nothing
--             , opts     = noFlags }

-- -- | A specifier of depth of the treePrint process.
-- type Depth = VConf -> VConf

-- -- | Sets the maxDepth of a configuration to the specified value.
-- depth :: Int -> Depth
-- depth d c = c { maxDepth = Just d }
-- {-# INLINE depth #-}

-- -- | Unlimits the maxDepth of a configuration.
-- boundless :: Depth
-- boundless c = c { maxDepth = Nothing }
-- {-# INLINE boundless #-}

-- applySwitch :: Switch -> VConf -> VConf
-- applySwitch switch c@Conf { opts = opts' } = c { opts = switch opts' }
-- {-# INLINE applySwitch #-}

-- -- STM IMPL

-- stmImpl :: Impl STM ShowS
-- stmImpl = str

-- -- WMES VISUALIZATION

-- instance Vnable Wme where
--   toVnShow = showWme
--   toVnAdjs = adjsWme

-- showWme :: Wme -> Flags -> Visited -> STM ShowS
-- showWme wme flags vs =
--   withEllipsis (visited wme vs) $
--     if is WmeSymbolic flags
--       then showWmeSymbolic                wme
--       else showWmeExplicit (is WmeIds flags) wme
-- {-# INLINE showWme #-}

-- showWmeSymbolic :: Wme -> ShowS
-- showWmeSymbolic wme = compose [showString "w", shows $ wmeId wme]
-- {-# INLINE showWmeSymbolic #-}

-- showWmeExplicit :: Bool -> Wme -> ShowS
-- showWmeExplicit oid
--   Wme { wmeId = id', wmeObj = obj, wmeAttr = attr, wmeVal = val } =
--     withOptIdS oid
--       (compose [ showString "("
--                , shows obj,  showString ","
--                , shows attr, showString ",", shows val
--                , showString ")"])
--       id'
-- {-# INLINE showWmeExplicit #-}

-- showWmeMaybe :: (Wme -> ShowS) -> Maybe Wme -> ShowS
-- showWmeMaybe _ Nothing    = showString "_"
-- showWmeMaybe f (Just wme) = f wme
-- {-# INLINE showWmeMaybe #-}

-- adjsWme :: Wme -> Flags -> Visited -> STM [Vn]
-- adjsWme
--   wme@Wme { wmeAmems                = amems
--           , wmeToks                 = toks
--           , wmeNegJoinResults       = jresults} flags vs =
--     whenNot (visited wme vs) $ do
--       let vs' = visiting wme vs
--       amemsVn <- netPropVn flags (is WmeAmems flags) "amems" vs' (readTVar amems)
--       toksVn  <- datPropVn flags (is WmeToks  flags) "toks"  vs' (readTVar toks)
--       njrsVn  <- datPropVn flags (is WmeNegJoinResults flags)
--                  "neg. ⊳⊲ results (owners)" vs'
--                  -- When visualizing the negative join results we only
--                  -- show the owner tokens, cause wme in every negative join
--                  -- result is this wme.
--                  (mapMM (return . negativeJoinResultOwner) (toListT jresults))

--       optVns [amemsVn, toksVn, njrsVn]
-- {-# INLINE adjsWme #-}

-- -- TOKENS VISUALIZATION

-- instance Vnable Tok where
--   toVnAdjs = adjsTok
--   toVnShow = showTok

-- showTok :: Tok -> Flags -> Visited -> STM ShowS
-- showTok tok@DummyTopTok {} flags vs =
--   withEllipsis (visited tok vs) $
--     withOptIdS (is TokIds flags) (showString "{}") (-1)

-- showTok tok flags vs = do
--     let s = if is TokWmes flags
--               then (if is TokWmesSymbolic flags
--                       then showTokWmesSymbolic tok
--                       else showTokWmesExplicit (is WmeIds flags) tok)
--               else showString "{..}"
--     withEllipsis (visited tok vs) $
--       withOptIdS (is TokIds flags) s (tokId tok)
-- {-# INLINE showTok #-}

-- showTokWmesSymbolic :: Tok -> ShowS
-- showTokWmesSymbolic = showTokWmes showWmeSymbolic
-- {-# INLINE showTokWmesSymbolic #-}

-- showTokWmesExplicit :: Bool -> Tok -> ShowS
-- showTokWmesExplicit owmeids = showTokWmes (showWmeExplicit owmeids)
-- {-# INLINE showTokWmesExplicit #-}

-- showTokWmes :: (Wme -> ShowS) -> Tok -> ShowS
-- showTokWmes f = rcompose
--               . intersperse (showString ",")
--               . map (showWmeMaybe f)
--               . tokWmes
-- {-# INLINE showTokWmes #-}

-- adjsTok :: Tok -> Flags -> Visited -> STM [Vn]
-- adjsTok tok@DummyTopTok { tokNode  = node
--                         , tokChildren  = children } flags vs =
--   whenNot (visited tok vs) $ do
--     let vs' = visiting tok vs
--     nodeVn     <- netPropVn flags (is TokNodes flags) "node" vs'
--                   (return [node])
--     childrenVn <- datPropVn flags (is TokChildren flags) "children" vs'
--                   (readTVar children)
--     optVns [nodeVn, childrenVn]

-- adjsTok
--   tok@Tok { tokParent         = parent
--           , tokOwner          = mowner
--           , tokNode           = node
--           , tokChildren       = children
--           , tokNegJoinResults = jresults
--           , tokNccResults     = nresults } flags vs =
--     whenNot (visited tok vs) $ do
--       let vs' = visiting tok vs
--       nodeVn     <- netPropVn flags (is TokNodes   flags) "node"   vs' (return [node])
--       parentVn   <- datPropVn flags (is TokParents flags) "parent" vs' (return [parent])
--       ownerVn    <- datPropVn flags (is TokOwners  flags) "owner"  vs'
--                     (liftM owner (readTVar mowner))
--       childrenVn <- datPropVn flags (is TokChildren flags) "children" vs'
--                       (readTVar children)
--       jresultsVn <- datPropVn flags (is TokJoinResults flags) "neg. ⊳⊲ results (wmes)"
--                       vs'
--                       -- When visualizing the negative join results we only
--                       -- show the wmes, cause owner in every negative join
--                       -- result is this tok(en).
--                       (mapMM (return . negativeJoinResultWme) (toListT jresults))
--       nresultsVn <- datPropVn flags (is TokNccResults flags) "ncc results" vs'
--                       (readTVar nresults)
--       optVns [nodeVn, parentVn, ownerVn, childrenVn, jresultsVn, nresultsVn]
--     where
--       owner ow = case ow of
--         Nothing -> []
--         Just o  -> [o]
-- {-# INLINE adjsTok #-}

-- -- AMEMS VISUALIZATION

-- instance Vnable Amem where
--   toVnAdjs = adjsAmem
--   toVnShow = showAmem

-- showAmem :: Amem -> Flags -> Visited -> STM ShowS
-- showAmem
--   amem@Amem { amemObj            = obj
--             , amemAttr           = attr
--             , amemVal            = val
--             , amemReferenceCount = rcount } flags vs = do
--     let alpha = showString "α"
--     let repr  = if is AmemFields flags
--                   then compose [alpha, showString " ("
--                                 , sS obj,  showString ","
--                                 , sS attr, showString ","
--                                 , sS val
--                                 , showString ")"]
--                   else alpha
--     withEllipsisT (visited amem vs) $
--       if is AmemRefCounts flags
--         then (do rc <- readTVar rcount
--                  return $ compose [repr, showString " refcount ", shows rc])
--         else return repr
--   where
--     sS s | s == wildcardSymbol = showString "*"
--          | otherwise           = shows s
-- {-# INLINE showAmem #-}

-- adjsAmem :: Amem -> Flags -> Visited -> STM [Vn]
-- adjsAmem
--   amem@Amem { amemSuccessors  = succs
--             , amemWmes        = wmes } flags vs =
--     whenNot (visited amem vs) $ do
--       let vs' = visiting amem vs
--       succVn <- netPropVn flags (is AmemSuccessors flags) "successors" vs'
--                 (readTVar succs)
--       wmesVn <- datPropVn flags (is AmemWmes flags) "wmes" vs' (readTVar wmes)
--       optVns [succVn, wmesVn]
-- {-# INLINE adjsAmem #-}

-- -- NODE VISUALIZATION

-- instance Vnable Node where
--   toVnAdjs = adjsNode
--   toVnShow = showNode

-- showNode :: Node -> Flags -> Visited -> STM ShowS
-- showNode node@DummyTopNode {} _ vs =
--   withEllipsis (visited node vs) $ showString "DTN (β)"

-- showNode node flags vs = do
--   let variant = nodeVariant node
--   s <- case variant of
--     Bmem       {} -> showBmem       variant flags
--     JoinNode   {} -> showJoinNode   variant flags
--     NegNode    {} -> showNegNode    variant flags
--     NccNode    {} -> showNccNode    variant flags
--     NccPartner {} -> showNccPartner variant flags
--     PNode      {} -> showPNode      variant flags
--     DTN        {} -> unreachableCode "showNode"

--   withEllipsis (visited node vs) $
--     withOptIdS (is NodeIds flags) s (nodeId node)
-- {-# INLINE showNode #-}

-- adjsNode :: Node -> Flags -> Visited -> STM [Vn]
-- adjsNode node@DummyTopNode { nodeVariant = variant } flags vs =
--   whenNot (visited node vs) $ do
--     let vs' = visiting node vs
--     -- In the case of DTM, just like in any β memory, we traverse down
--     -- using all children, also the unlinked ones.
--     childrenVn <- netPropVn flags (is NodeChildren flags) "children (with all)" vs'
--                   (bmemLikeChildren node)
--                   -- (rvprop bmemAllChildren node)
--     variantVns <- adjsDTN variant flags vs'
--     optVns (variantVns ++ [childrenVn])

-- adjsNode
--   node@Node { nodeParent    = parent
--             , nodeChildren  = children
--             , nodeVariant   = variant } flags vs =
--     whenNot (visited node vs) $ do
--       let vs' = visiting node vs
--       parentVn <- netPropVn flags (is NodeParents  flags) "parent" vs'
--                   (return [parent])

--       -- In the case of β memory, we traverse down using all children,
--       -- also the unlinked ones.
--       childrenVn <- if isBmemLike variant
--                       then netPropVn flags (is NodeChildren flags)
--                            "children (with all)" vs' (bmemLikeChildren node)
--                       else netPropVn flags (is NodeChildren flags) "children"
--                            vs' (readTVar children)

--       variantVns <- case variant of
--         Bmem       {} -> adjsBmem       variant flags vs'
--         JoinNode   {} -> adjsJoinNode   variant flags vs'
--         NegNode    {} -> adjsNegNode    variant flags vs'
--         NccNode    {} -> adjsNccNode    variant flags vs'
--         NccPartner {} -> adjsNccPartner variant flags vs'
--         PNode      {} -> adjsPNode      variant flags vs'
--         DTN        {} -> unreachableCode "adjsNode"

--       optVns (variantVns ++ [parentVn, childrenVn])
-- {-# INLINE adjsNode #-}

-- -- Bmem VISUALIZATION

-- showBmem :: NodeVariant -> Flags ->  STM ShowS
-- showBmem _ _ = return (showString "β")
-- {-# INLINE showBmem #-}

-- adjsBmem :: NodeVariant -> Flags -> Visited -> STM [Maybe Vn]
-- adjsBmem Bmem { nodeToks = toks } flags vs' = adjsBmemLike toks flags vs'
-- adjsBmem _                        _  _   = unreachableCode "adjsBmem"
-- {-# INLINE adjsBmem #-}

-- isBmemLike :: NodeVariant -> Bool
-- isBmemLike Bmem {} = True
-- isBmemLike DTN  {} = True
-- isBmemLike _       = False
-- {-# INLINE isBmemLike #-}

-- adjsBmemLike :: TSet Tok -> Flags -> Visited -> STM [Maybe Vn]
-- adjsBmemLike toks flags vs' = do
--     toksVn <- datPropVn flags (is BmemToks flags) "toks" vs' (readTVar toks)
--     return [toksVn]
-- {-# INLINE adjsBmemLike #-}

-- -- | In the case of Bmems and STM We merge nodeChildren and
-- -- bmemAllChildren.
-- bmemLikeChildren :: Node -> STM (Set.HashSet Node)
-- bmemLikeChildren node = do
--   children    <- liftM Set.fromList (toListT (nodeChildren node))
--   allChildren <- rvprop bmemAllChildren node
--   return (children `Set.union` allChildren)
-- {-# INLINE bmemLikeChildren #-}

-- -- DTN VISUALIZATION

-- adjsDTN :: NodeVariant -> Flags -> Visited -> STM [Maybe Vn]
-- adjsDTN DTN { nodeToks = toks } flags vs' = adjsBmemLike toks flags vs'
-- adjsDTN _                       _  _   = unreachableCode "adjsDTN"
-- {-# INLINE adjsDTN #-}

-- -- JoinNode VISUALIZATION

-- showJoinNode :: NodeVariant -> Flags -> STM ShowS
-- showJoinNode JoinNode { leftUnlinked = lu, rightUnlinked = ru } flags =
--     if is Uls flags
--       then (do mark <- ulMark lu ru
--                return (showString ('⊳':'⊲':' ':mark)))
--       else return (showString "⊳⊲")

-- showJoinNode _ _ = unreachableCode "showJoinNode"
-- {-# INLINE showJoinNode #-}

-- ulSign :: Bool -> Char
-- ulSign True  = '-'  -- unlinked
-- ulSign False = '+'  -- linked
-- {-# INLINE ulSign #-}

-- ulMark :: TVar Bool -> TVar Bool -> STM String
-- ulMark lu ru = do
--   l <- readTVar lu
--   r <- readTVar ru
--   return [ulSign l, '/', ulSign r]
-- {-# INLINE ulMark #-}

-- ulSingleMark :: TVar Bool -> STM String
-- ulSingleMark unl = do
--   u <- readTVar unl
--   return ['/', ulSign u]
-- {-# INLINE ulSingleMark #-}

-- adjsJoinNode :: NodeVariant -> Flags -> Visited -> STM [Maybe Vn]
-- adjsJoinNode
--   JoinNode { joinTests                   = tests
--            , nodeAmem                    = amem
--            , nearestAncestorWithSameAmem = ancestor } flags vs' = do
--     testsVn    <- netPropVn flags (is JoinTests flags) "tests" vs' (return tests)
--     amemVn     <- netPropVn flags (is JoinAmems flags) "amem"  vs' (return [amem])
--     ancestorVn <- netPropVn flags (is JoinNearestAncestors flags) "ancestor" vs'
--                   (joinAncestorM ancestor)
--     return [amemVn, ancestorVn, testsVn]

-- adjsJoinNode _ _ _ = unreachableCode "adjsJoinNode"

-- joinAncestorM :: Monad m => Maybe a -> m [a]
-- joinAncestorM ancestor = case ancestor of
--   Nothing -> return []
--   Just a  -> return [a]
-- {-# INLINE joinAncestorM #-}

-- -- NegNode VISUALIZATION

-- showNegNode :: NodeVariant -> Flags -> STM ShowS
-- showNegNode
--   NegNode { rightUnlinked = ru } flags =
--     if is Uls flags
--       then (do mark <- ulSingleMark ru
--                return (showString ('¬':' ':mark)))
--       else return (showString "¬")

-- showNegNode _ _ = unreachableCode "showNegNode"
-- {-# INLINE showNegNode #-}

-- adjsNegNode :: NodeVariant -> Flags -> Visited -> STM [Maybe Vn]
-- adjsNegNode
--   NegNode { joinTests                   = tests
--           , nodeAmem                    = amem
--           , nearestAncestorWithSameAmem = ancestor
--           , nodeToks                  = toks} flags vs' = do
--     amemVn     <- netPropVn flags (is NegAmems flags) "amem"  vs' (return [amem])
--     testsVn    <- netPropVn flags (is NegTests flags) "tests" vs' (return tests)
--     ancestorVn <- netPropVn flags (is NegNearestAncestors flags) "ancestor" vs'
--                     (joinAncestorM ancestor)
--     toksVn     <- datPropVn flags (is NegToks  flags) "toks" vs' (readTVar toks)
--     return [amemVn, ancestorVn, testsVn, toksVn]

-- adjsNegNode _ _ _ = unreachableCode "adjsNegNode"

-- -- NccNode VISUALIZATION

-- showNccNode :: NodeVariant -> Flags -> STM ShowS
-- showNccNode NccNode {} _ = return (showString "Ncc")
-- showNccNode _          _ = unreachableCode "showNccNode"
-- {-# INLINE showNccNode #-}

-- adjsNccNode :: NodeVariant -> Flags -> Visited -> STM [Maybe Vn]
-- adjsNccNode NccNode { nodeToks = toks, nccPartner = partner } flags vs' = do
--     partnerVn <- netPropVn flags (is NccPartners flags) "partner" vs'
--                  (return [partner])
--     toksVn    <- datPropVn flags (is NccToks flags) "toks" vs'
--                  (readTVar toks)
--     return [partnerVn, toksVn]

-- adjsNccNode _ _ _ = unreachableCode "adjsNccNode"
-- {-# INLINE adjsNccNode #-}

-- -- NccPartner VISUALIZATION

-- showNccPartner :: NodeVariant -> Flags -> STM ShowS
-- showNccPartner NccPartner { nccPartnerNumberOfConjucts = conjs  } flags =
--     if is NccNumberOfConjucts flags
--       then return (compose [showString "Ncc (P) conjucts ", shows conjs])
--       else return (showString "Ncc (P)")

-- showNccPartner _ _ = unreachableCode "showNccPartner"
-- {-# INLINE showNccPartner #-}

-- adjsNccPartner :: NodeVariant -> Flags -> Visited -> STM [Maybe Vn]
-- adjsNccPartner
--   NccPartner { nccPartnerNccNode       = node
--              , nccPartnerNewResultBuff = buff } flags vs' = do
--     node'  <- readTVar node
--     nodeVn <- netPropVn flags (is NccNodes flags)
--                 "ncc node" vs' (return [fromJust node'])
--     toksVn <- datPropVn flags (is NccNewResultBuffs flags)
--                 "new result buff." vs' (readTVar buff)
--     return [nodeVn, toksVn]

-- adjsNccPartner _ _ _ = unreachableCode "adjsNccPartner"
-- {-# INLINE adjsNccPartner #-}

-- -- PNode VISUALIZATION

-- showPNode :: NodeVariant -> Flags -> STM ShowS
-- showPNode PNode {} _ = return (showString "P")
-- showPNode _        _ = unreachableCode "showPNode"
-- {-# INLINE showPNode #-}

-- adjsPNode :: NodeVariant -> Flags -> Visited -> STM [Maybe Vn]
-- adjsPNode
--   PNode { nodeToks              = toks
--         , pnodeVariableBindings = bindings } flags vs' = do
--     toksVn <- datPropVn flags (is PNodeToks     flags) "toks" vs' (readTVar toks)
--     varsVn <- netPropVn flags (is PNodeBindings flags) "vars" vs' (varlocs bindings)
--     return [varsVn, toksVn]

-- adjsPNode _ _ _ = unreachableCode "adjsPNode"
-- {-# INLINE adjsPNode #-}

-- -- VARIABLE LOCATIONS CREATION AND VISUALIZATION

-- data VLoc = VLoc !Symbol !Field !Distance

-- varlocs :: VariableBindings -> STM [VLoc]
-- varlocs = return . map vbinding2VLoc . Map.toList
--   where vbinding2VLoc (s, SymbolLocation f d) = VLoc s f d
-- {-# INLINE varlocs #-}

-- instance Vnable VLoc where
--   toVnAdjs = adjsVLoc
--   toVnShow = showVLoc

-- showVLoc :: VLoc -> Flags -> Visited -> STM ShowS
-- showVLoc (VLoc s f d) _ _ =
--   return (compose [ shows s, showString " → "
--                   , shows d, showString ",", shows f])
-- {-# INLINE showVLoc #-}

-- adjsVLoc :: VLoc -> Flags -> Visited -> STM [Vn]
-- adjsVLoc _ _ _ = return []
-- {-# INLINE adjsVLoc #-}

-- -- JoinTest VISUALIZATION

-- instance Vnable JoinTest where
--   toVnAdjs = adjsJoinTest
--   toVnShow = showJoinTest

-- showJoinTest :: JoinTest -> Flags -> Visited -> STM ShowS
-- showJoinTest
--   JoinTest { joinTestField1   = f1
--            , joinTestField2   = f2
--            , joinTestDistance = d } _ _ =
--     return (compose [ showString "⟨"
--                     , shows f1, showString ","
--                     , shows d,  showString ","
--                     , shows f2
--                     , showString "⟩"])
-- {-# INLINE showJoinTest #-}

-- adjsJoinTest :: JoinTest -> Flags -> Visited -> STM [Vn]
-- adjsJoinTest _ _ _ = return []
-- {-# INLINE adjsJoinTest #-}

-- -- MISC.

-- unreachableCode :: String -> a
-- unreachableCode tag
--   = error ("Unreachable code. Impossible has happened!!! " ++ tag)
-- {-# INLINE unreachableCode #-}

-- -- PRINT IMPLEMENTATION

-- -- | Converts the selected object to a tree representation (expressed
-- -- in ShowS).
-- toShowS :: Vnable a => Depth -> Switch -> a -> STM ShowS
-- toShowS d switch obj = printTree (switches conf) (toVn cleanVisited obj)
--   where switches = d . applySwitch switch
-- {-# INLINE toShowS #-}

-- -- | Works like toShowS, but returns String instead of ShowS
-- toString :: Vnable a => Depth -> Switch -> a -> STM String
-- toString d switch = liftM evalShowS . toShowS d switch
--   where evalShowS s = s ""
-- {-# INLINE toString #-}

-- -- PREDEFINED PRINT CONFIGURATIONS

-- -- | A 'Switch' for presenting sole Rete net bottom-up.
-- soleNetBottomUp :: Switch
-- soleNetBottomUp = up . with NetEmph . withNet . withIds . with AmemFields
--                 . with Uls

-- -- | A 'Switch' for presenting sole Rete net top-down.
-- soleNetTopDown :: Switch
-- soleNetTopDown = down . with NetEmph . withNet . withIds . with AmemFields
--                . with Uls
