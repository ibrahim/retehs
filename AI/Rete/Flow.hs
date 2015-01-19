{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# OPTIONS_GHC -W -Wall #-}
------------------------------------------------------------------------
-- |
-- Module      : AI.Rete.Flow
-- Copyright   : (c) 2014 Konrad Grzanek
-- License     : BSD-style (see the file LICENSE)
-- Created     : 2014-12-22
-- Maintainer  : kongra@gmail.com
-- Stability   : experimental
-- Portability : requires stm
------------------------------------------------------------------------
module AI.Rete.Flow where

import           AI.Rete.Data
import           Control.Concurrent.STM
import           Control.Monad (when, unless, liftM, liftM2, forM_)
import           Data.Foldable (Foldable, toList)
import qualified Data.HashMap.Strict as Map
import qualified Data.HashSet as Set
import           Data.Hashable (Hashable)
import           Data.Maybe (fromMaybe)
import qualified Data.Sequence as Seq
import           Kask.Control.Monad (mapMM_, forMM_, toListM, whenM)
import           Kask.Data.Sequence (removeFirstOccurence)

-- MISC. UTILS

-- | A monadic (in STM monad) version of Set.null.
nullTSet :: TVar (Set.HashSet a) -> STM Bool
nullTSet = liftM Set.null . readTVar
{-# INLINE nullTSet #-}

-- | A monadic (in STM monad) version of Data.Foldable.toList.
toListT :: Foldable f => TVar (f a) -> STM [a] -- TSeq a -> STM [a]
toListT = toListM . readTVar
{-# INLINE toListT #-}

class ToBool a where toBool :: a -> Bool

-- WMES INDEXES MANIPULATION

type WmesIndexOperator a =
  (Hashable a, Eq a) => a -> Wme -> WmesIndex a -> WmesIndex a

-- | Creates an updated version of the wme index by putting a new
-- wme under the key k.
wmesIndexInsert ::  WmesIndexOperator a
wmesIndexInsert k wme index = Map.insert k newSet index
  where oldSet = Map.lookupDefault Set.empty k index
        newSet = Set.insert wme oldSet
{-# INLINE wmesIndexInsert #-}

-- | Removes the passed wme (possibly) stored under the key k from the
-- index.
wmesIndexDelete :: WmesIndexOperator a
wmesIndexDelete k wme index =
  case Map.lookup k index of
    Nothing     -> index
    Just oldSet -> Map.insert k (Set.delete wme oldSet) index
{-# INLINE wmesIndexDelete #-}

-- ENVIRONMENT

-- | Creates and returns a new, empty Env.
createEnv :: STM Env
createEnv = do
  idState    <- newTVar 0
  constants  <- newTVar Map.empty
  variables  <- newTVar Map.empty
  wmes       <- newTVar Map.empty
  wmesByObj  <- newTVar Map.empty
  wmesByAttr <- newTVar Map.empty
  wmesByVal  <- newTVar Map.empty
  amems      <- newTVar Map.empty
  prods      <- newTVar Set.empty

  return Env { envIdState    = idState
             , envConstants  = constants
             , envVariables  = variables
             , envWmes       = wmes
             , envWmesByObj  = wmesByObj
             , envWmesByAttr = wmesByAttr
             , envWmesByVal  = wmesByVal
             , envAmems      = amems
             , envProds      = prods }

feedEnvIndexes :: Env -> Wme -> STM ()
feedEnvIndexes
  Env     { envWmesByObj  = byObj
          , envWmesByAttr = byAttr
          , envWmesByVal  = byVal }
  wme@Wme { wmeObj        = obj
          , wmeAttr       = attr
          , wmeVal        = val } = do

    let w = Const wildcardConstant

    modifyTVar' byObj  (wmesIndexInsert obj      wme)
    modifyTVar' byObj  (wmesIndexInsert (Obj w)  wme)

    modifyTVar' byAttr (wmesIndexInsert attr     wme)
    modifyTVar' byAttr (wmesIndexInsert (Attr w) wme)

    modifyTVar' byVal  (wmesIndexInsert val      wme)
    modifyTVar' byVal  (wmesIndexInsert (Val w)  wme)
{-# INLINE feedEnvIndexes #-}

deleteFromEnvIndexes :: Env -> Wme -> STM ()
deleteFromEnvIndexes
  Env     { envWmesByObj  = byObj
          , envWmesByAttr = byAttr
          , envWmesByVal  = byVal}
  wme@Wme { wmeObj        = obj
          , wmeAttr       = attr
          , wmeVal        = val } = do

    let w = Const wildcardConstant

    modifyTVar' byObj  (wmesIndexDelete obj      wme)
    modifyTVar' byObj  (wmesIndexDelete (Obj w)  wme)

    modifyTVar' byAttr (wmesIndexDelete attr     wme)
    modifyTVar' byAttr (wmesIndexDelete (Attr w) wme)

    modifyTVar' byVal  (wmesIndexDelete val      wme)
    modifyTVar' byVal  (wmesIndexDelete (Val w)  wme)
{-# INLINE deleteFromEnvIndexes #-}

-- GENERATING IDS

-- | Generates a new Id.
genid :: Env -> STM Id
genid Env { envIdState = eid } = do
  recent <- readTVar eid

  -- Hopefully not in a achievable time, but ...
  when (recent == maxBound) (error "PANIC (1): Id OVERFLOW.")

  let new = recent + 1
  writeTVar eid new
  return new
{-# INLINE genid #-}

-- SPECIAL SYMBOLS

emptyConstant :: Constant
emptyConstant =  Constant (-1) ""

emptyVariable :: Variable
emptyVariable =  Variable (-2) "?"

wildcardConstant :: Constant
wildcardConstant = Constant (-3) "*"

-- INTERNING CONSTANTS AND VARIABLES

class InternSymbol a where
  -- | Interns and returns a Symbol for the name argument.
  internSymbol :: Env -> a -> STM Symbol

instance InternSymbol Symbol where
  -- We may simply return the argument here, because Constants and
  -- Variables once interned never expire (get un-interned). Otherwise
  -- we would have to intern the argument's name.
  internSymbol _ = return

instance InternSymbol S where
  internSymbol env (S   s) = internSymbol env s
  internSymbol env (Sym s) = internSymbol env s

instance InternSymbol String where
  internSymbol env name = case symbolName name of
    EmptyConst     -> return (Const emptyConstant)
    EmptyVar       -> return (Var   emptyVariable)
    OneCharConst   -> liftM  Const (internConstant env name)
    MultiCharVar   -> liftM  Var   (internVariable env name)
    MultiCharConst -> liftM  Const (internConstant env name)

data SymbolName = EmptyConst
                | EmptyVar
                | OneCharConst
                | MultiCharVar
                | MultiCharConst deriving Show

symbolName :: String -> SymbolName
symbolName "" = EmptyConst
symbolName [c]
  | c == '?'  = EmptyVar
  | otherwise = OneCharConst
symbolName (c:_:_)
  | c == '?'  = MultiCharVar
  | otherwise = MultiCharConst
{-# INLINE symbolName #-}

internConstant :: Env -> String -> STM Constant
internConstant env name = do
  cs <- readTVar (envConstants env)
  case Map.lookup name cs of
    Just c  -> return c
    Nothing -> do
      id' <- genid env
      let c = Constant id' name
      writeTVar (envConstants env) $! Map.insert name c cs
      return c
{-# INLINE internConstant #-}

internVariable :: Env -> String -> STM Variable
internVariable env name = do
  vs <- readTVar (envVariables env)
  case Map.lookup name vs of
    Just v  -> return v
    Nothing -> do
      id' <- genid env
      let v = Variable id' name
      writeTVar (envVariables env) $! Map.insert name v vs
      return v
{-# INLINE internVariable #-}

-- ACCESSING SYMBOLS (ALREADY INTERNED)

-- | Only if there is an interned symbol of the given name, returns
-- Just it, Nothing otherwise.
internedSymbol :: Env -> String -> STM (Maybe Symbol)
internedSymbol env name = case symbolName name of
    EmptyConst     -> return $! Just (Const emptyConstant)
    EmptyVar       -> return $! Just (Var   emptyVariable)
    OneCharConst   -> internedConstant env name
    MultiCharVar   -> internedVariable env name
    MultiCharConst -> internedConstant env name
{-# INLINE internedSymbol #-}

internedConstant :: Env -> String -> STM (Maybe Symbol)
internedConstant Env { envConstants = consts } name = do
  cs <- readTVar consts
  case Map.lookup name cs of
    Nothing -> return Nothing
    Just c  -> return $! Just (Const c)
{-# INLINE internedConstant #-}

internedVariable :: Env -> String -> STM (Maybe Symbol)
internedVariable Env { envVariables = vars } name = do
  vs <- readTVar vars
  case Map.lookup name vs of
    Nothing -> return Nothing
    Just v  -> return $! Just (Var v)
{-# INLINE internedVariable #-}

-- ALPHA MEMORY

-- | Activates the alpha memory by passing it a wme.
activateAmem :: Env -> Amem -> Wme -> STM ()
activateAmem env amem wme = do
  -- Add wme to amem's registry and indices.
  modifyTVar' (amemWmes       amem) (Set.insert                    wme)
  modifyTVar' (amemWmesByObj  amem) (wmesIndexInsert (wmeObj  wme) wme)
  modifyTVar' (amemWmesByAttr amem) (wmesIndexInsert (wmeAttr wme) wme)
  modifyTVar' (amemWmesByVal  amem) (wmesIndexInsert (wmeVal  wme) wme)

  -- Add amem to wme's amems.
  modifyTVar' (wmeAmems wme) (amem:)

  -- Activate amem successors.
  mapMM_ (rightActivateAmemSuccessor env wme) (toListT (amemSuccessors amem))

rightActivateAmemSuccessor :: Env -> Wme -> AmemSuccessor -> STM ()
rightActivateAmemSuccessor = undefined

-- WMES

class AddWme a where
  -- | Adds the fact represented by the Wme fields into the working
  -- memory and propagates the change downwards the Rete network. Returns
  -- the corresponding Wme. If the fact was already present, nothing
  -- happens, and Nothing is being returned.
  addWme :: Env -> a -> a -> a -> STM (Maybe Wme)

-- | Works like addWme inside an action (of a production).
addWmeA :: AddWme a => Actx -> a -> a -> a -> STM (Maybe Wme)
addWmeA actx = addWme (actxEnv actx)
{-# INLINE addWmeA #-}

instance AddWme String where addWme = addWmeInterningFields
instance AddWme S      where addWme = addWmeInterningFields

addWmeInterningFields :: InternSymbol a => Env -> a -> a -> a -> STM (Maybe Wme)
addWmeInterningFields env obj attr val = do
  obj'  <- internSymbol env obj
  attr' <- internSymbol env attr
  val'  <- internSymbol env val
  addWme env obj' attr' val'
{-# INLINE addWmeInterningFields #-}

instance AddWme Symbol where
  addWme env obj attr val = do
    let k = WmeKey (Obj obj) (Attr attr) (Val val)
    wmes <- readTVar (envWmes env)
    if Map.member k wmes
      then return Nothing -- Already present, do nothing.
      else do
        wme <- createWme env (Obj obj) (Attr attr) (Val val)

        -- Add wme to envWmes under k.
        writeTVar (envWmes env) $! Map.insert k wme wmes

        -- Add wme to env indexes (including wildcard key).
        feedEnvIndexes env wme

        -- Propagate wme into amems and return.
        feedAmems env wme (Obj obj) (Attr attr) (Val val)
        return (Just wme)

-- | Creates an empty Wme.
createWme :: Env -> Obj -> Attr -> Val -> STM Wme
createWme env obj attr val = do
  id'       <- genid env
  amems     <- newTVar []
  toks      <- newTVar Set.empty
  njResults <- newTVar Set.empty

  return Wme { wmeId             = id'
             , wmeObj            = obj
             , wmeAttr           = attr
             , wmeVal            = val
             , wmeAmems          = amems
             , wmeToks           = toks
             , wmeNegJoinResults = njResults }
{-# INLINE createWme #-}

-- | Looks for an Amem corresponding with WmeKey k and activates
-- it. Does nothing unless finds one.
feedAmem :: Env -> Map.HashMap WmeKey Amem -> Wme -> WmeKey -> STM ()
feedAmem env amems wme k = case Map.lookup k amems of
  Just amem -> activateAmem env amem wme
  Nothing   -> return ()
{-# INLINE feedAmem #-}

-- | Feeds proper Amems with a Wme.
feedAmems :: Env -> Wme -> Obj -> Attr -> Val -> STM ()
feedAmems env wme o a v = do
  let w = Const wildcardConstant
  amems <- readTVar (envAmems env)

  feedAmem env amems wme $! WmeKey o       a        v
  feedAmem env amems wme $! WmeKey o       a        (Val w)
  feedAmem env amems wme $! WmeKey o       (Attr w) v
  feedAmem env amems wme $! WmeKey o       (Attr w) (Val w)

  feedAmem env amems wme $! WmeKey (Obj w) a        v
  feedAmem env amems wme $! WmeKey (Obj w) a        (Val w)
  feedAmem env amems wme $! WmeKey (Obj w) (Attr w) v
  feedAmem env amems wme $! WmeKey (Obj w) (Attr w) (Val w)
{-# INLINE feedAmems #-}

-- TOKS

-- | Creates a new Tok. It DOES NOT add it to the node (see
-- makeAndInsertTok).
makeTok :: Env -> ParentTok -> Maybe Wme -> TokNode -> STM Tok
makeTok env parent wme node = do
  id'        <- genid   env
  children   <- newTVar Set.empty
  njResults  <- newTVar Set.empty
  nccResults <- newTVar Set.empty
  owner      <- newTVar Nothing

  let tok = Tok { tokId             = id'
                , tokParent         = parent
                , tokWme            = wme
                , tokNode           = node
                , tokChildren       = children
                , tokNegJoinResults = njResults
                , tokNccResults     = nccResults
                , tokOwner          = owner}

  -- Add tok to parent.children (for tree-based removal) ...
  case parent of
    ParentTok p -> modifyTVar' (tokChildren p) (Set.insert tok)
    Dtt         -> return () -- ... but only unless Dtt (a rhetorical figure
                             --     that is never deleted).

  -- Add tok to wme.tokens (for tree-based-removal) ...
  case wme of
    Just w  -> modifyTVar' (wmeToks w) (Set.insert tok)
    Nothing -> return () -- ... but only when wme is present.

  return tok
{-# INLINE makeTok #-}

-- | Creates a new Tok and adds it to the tokset (presumably in the node).
makeAndInsertTok :: Env -> ParentTok -> Maybe Wme
                 -> TokNode -> TVar TokSet
                 -> STM Tok
makeAndInsertTok env parent wme node tokset = do
  tok <- makeTok env parent wme node
  modifyTVar' tokset (Set.insert tok)
  return tok
{-# INLINE makeAndInsertTok #-}

tokWmes :: Tok -> [Maybe Wme]
tokWmes = loop . ParentTok
  where
    loop (ParentTok tok) = tokWme tok : loop (tokParent tok)
    loop Dtt             = []
{-# INLINE tokWmes #-}

-- BMEM

-- | Performs left-activation of a Bmem.
leftActivateBmem :: Env -> Bmem -> ParentTok -> Wme -> STM ()
leftActivateBmem env bmem parent wme = do
  tok <- makeAndInsertTok env parent (Just wme) (BmemTokNode bmem)
         (bmemToks bmem)

  mapMM_ (rightActivateBmemChild env tok) (toListT (bmemChildren bmem))
{-# INLINE leftActivateBmem #-}

rightActivateBmemChild :: Env -> Tok -> BmemChild -> STM ()
rightActivateBmemChild = undefined

-- UNINDEXED JOIN

-- | Performs the join tests not using any kind of indexing. Useful
-- while right-activation, when the Amem passes a single Wme, so
-- there is no use of Amem indexing.
performJoinTests :: [JoinTest] -> Tok -> Wme -> Bool
performJoinTests tests tok wme = all (passJoinTest (tokWmes tok) wme) tests
{-# INLINE performJoinTests #-}

passJoinTest :: [Maybe Wme] -> Wme -> JoinTest -> Bool
passJoinTest wmes wme
  JoinTest { joinField1 = f1, joinField2 = f2, joinDistance = d } =
    fieldSymbol f1 wme == fieldSymbol f2 wme2
    where
      wme2 = fromMaybe (error "PANIC (2): wmes !! d RETURNED Nothing.")
                       (wmes !! d)
{-# INLINE passJoinTest #-}

-- | Returns a value of a Field in Wme.
fieldSymbol :: Field -> Wme -> Symbol
fieldSymbol O Wme { wmeObj  = Obj  s } = s
fieldSymbol A Wme { wmeAttr = Attr s } = s
fieldSymbol V Wme { wmeVal  = Val  s } = s
{-# INLINE fieldSymbol #-}

-- INDEXED JOIN

-- | Matches a token to wmes in Amem using the Amem's indexes.
matchingAmemWmes :: [JoinTest] -> Tok -> Amem -> STM [Wme]
matchingAmemWmes [] _ amem = toListT (amemWmes amem) -- No tests, take all Wmes.
matchingAmemWmes tests tok amem = -- At least one test specified.
  toListM (foldr (liftM2 Set.intersection) s sets)
  where
    (s:sets) = map (amemWmesForTest (tokWmes tok) amem) tests
{-# INLINE matchingAmemWmes #-}

amemWmesForTest :: [Maybe Wme] -> Amem -> JoinTest -> STM WmeSet
amemWmesForTest wmes amem
  JoinTest { joinField1 = f1, joinField2 = f2, joinDistance = d } =
    case f1 of
      O -> amemWmesForIndex (Obj  value) (amemWmesByObj  amem)
      A -> amemWmesForIndex (Attr value) (amemWmesByAttr amem)
      V -> amemWmesForIndex (Val  value) (amemWmesByVal  amem)
    where
      wme   = fromMaybe (error "PANIC (3): wmes !! d RETURNED Nothing.")
                        (wmes !! d)
      value = fieldSymbol f2 wme
{-# INLINE amemWmesForTest #-}

amemWmesForIndex :: (Hashable a, Eq a) => a -> TVar (WmesIndex a) -> STM WmeSet
amemWmesForIndex k index =
  liftM (Map.lookupDefault Set.empty k) (readTVar index)
{-# INLINE amemWmesForIndex #-}

-- JOIN

leftActivateJoin :: Env -> Join -> Tok -> STM ()
leftActivateJoin env join tok = do
  let amem = joinAmem join
  isAmemEmpty <- nullTSet (amemWmes amem)

  whenM (isRightUnlinked join) $ do -- When join.parent just became non-empty.
    relinkToAmem join
    when isAmemEmpty $ leftUnlink join (joinParent join)

  unless isAmemEmpty $ do
    children <- readTVar (joinChildren join)
    -- Only when we have children to activate ...
    unless (Seq.null children) $ do
      -- ... take matching Wmes from Amem indexes
      wmes <- matchingAmemWmes (joinTests join) tok amem
      -- and iterate all wmes over all children left-activating:
      forM_ wmes $ \wme -> forM_ (toList children) $ \child ->
        leftActivateJoinChild env child tok wme

leftActivateJoinChild :: Env -> JoinChild -> Tok -> Wme -> STM ()
leftActivateJoinChild = undefined

instance IsRightUnlinked Join where
  isRightUnlinked join = liftM toBool (readTVar (joinRightUnlinked join))

instance IsLeftUnlinked Join where
  isLeftUnlinked join = liftM toBool (readTVar (joinLeftUnlinked join))

instance LeftUnlink Join JoinParent where leftUnlink = undefined

instance RightUnlink Join where
  rightUnlink join amem = do
    writeTVar (joinRightUnlinked join) $! RightUnlinked True
    modifyTVar' (amemSuccessors amem)
      (removeFirstOccurence (JoinAmemSuccessor join))

rightActivateJoin :: Env -> Join -> Wme -> STM ()
rightActivateJoin env join wme = do
  let amem   = joinAmem   join
      parent = joinParent join

  parentTokSet <- joinParentTokSet parent
  let isParentEmpty = Set.null parentTokSet

  whenM (isLeftUnlinked join) $ do -- When join.amem just became non-empty.
    relinkToParent join
    when isParentEmpty (rightUnlink join amem)

  -- Only when parent has some Toks inside,
  unless isParentEmpty $ do
    children <- readTVar (joinChildren join)
    -- Only when there are some JoinChildren
    unless (Seq.null children) $
      -- Iterate over parent.toks ...
      forM_ (toList parentTokSet) $ \tok ->
        when (performJoinTests (joinTests join) tok wme) $
          -- ... and JoinChildren performing left activation.
          forM_ (toList children) $ \child ->
            leftActivateJoinChild env child tok wme

joinParentTokSet :: JoinParent -> STM TokSet
joinParentTokSet = undefined

-- NEG

leftActivateNeg :: Env -> Neg -> Tok -> Wme -> STM ()
leftActivateNeg env neg tok wme = do
  toks <- readTVar (negToks neg)
  whenM (isRightUnlinked neg) $
    -- The right-unlinking status above must be checked because a
    -- negative node is not right unlinked on creation.
    when (Set.null toks) $ relinkToAmem neg

  -- Build a new token and store it just like a Bmem would.
  newTok <- makeTok env (ParentTok tok) (Just wme) (NegTokNode neg)
  writeTVar (negToks neg) (Set.insert newTok toks)

  let amem = negAmem neg
  isAmemEmpty <- nullTSet (amemWmes amem)

  -- Compute the join results (using amem indexes)
  unless isAmemEmpty $ do
    wmes <- matchingAmemWmes (negTests neg) newTok amem
    forM_ wmes $ \w -> do
      let jr = NegJoinResult newTok w
      modifyTVar' (tokNegJoinResults newTok) (Set.insert jr)
      modifyTVar' (wmeNegJoinResults w)      (Set.insert jr)
      -- In the original Doorenbos pseudo-code there was a bug - wme
      -- was used instead of w in the 3 lines above.

  -- If join results are empty, then inform children.
  whenM (nullTSet (tokNegJoinResults newTok)) $
    mapMM_ (leftActivateNegChild env newTok) (toListT (negChildren neg))

leftActivateNegChild :: Env -> Tok -> NegChild -> STM ()
leftActivateNegChild = undefined

instance IsRightUnlinked Neg where
  isRightUnlinked neg = liftM toBool (readTVar (negRightUnlinked neg))

rightActivateNeg :: Env -> Neg -> Wme -> STM ()
rightActivateNeg env neg wme =
  forMM_ (toListT (negToks neg)) $ \tok ->
    when (performJoinTests (negTests neg) tok wme) $ do
      whenM (nullTSet (tokNegJoinResults tok)) $ deleteDescendentsOfTok env tok

      let jr = NegJoinResult tok wme
      -- Insert jr into tok.(neg)join-results.
      modifyTVar' (tokNegJoinResults tok) (Set.insert jr)
      -- Insert jr into wme.neg-join-results.
      modifyTVar' (wmeNegJoinResults wme) (Set.insert jr)

-- NCC

leftActivateNcc :: Env -> Ncc -> Tok -> Wme -> STM ()
leftActivateNcc env ncc tok wme = do
  let partner = nccPartner ncc

  -- Create a new token and add it to the nccToks index under a proper
  -- OwnerKey.
  newTok      <- makeTok env (ParentTok tok) (Just wme) (NccTokNode ncc)
  let ownerKey = OwnerKey    (ParentTok tok) (Just wme)
  modifyTVar' (nccToks ncc) (Map.insert ownerKey newTok)

  buff <- readTVar (partnerBuff partner)
  let isEmptyBuff = Set.null buff

  unless isEmptyBuff $ do
    -- Now we cut (clear) partner.buff and paste it into newTok.nccResults.
    writeTVar (partnerBuff   partner) Set.empty
    writeTVar (tokNccResults newTok)  buff
    -- For every result in buff result.owner = newTok
    forM_ (toList buff) $ \result -> writeTVar (tokOwner result) $! Just newTok

  when isEmptyBuff $
    -- No ncc results so inform children.
    mapMM_ (leftActivateNccChild env newTok) (toListT (nccChildren ncc))

leftActivateNccChild :: Env -> Tok -> NccChild -> STM ()
leftActivateNccChild = undefined

-- (NCC) PARTNER

leftActivatePartner :: Env -> Partner -> Tok -> Wme -> STM ()
leftActivatePartner env partner tok wme = do
  let ncc = partnerNcc partner
  newResult <- makeTok env (ParentTok tok) (Just wme) (PartnerTokNode partner)

  let n = partnerConjucts partner
      (ownerParent, ownerWme) = findOwnersPair n (ParentTok tok) (Just wme)
  owner <- findNccOwner ncc ownerParent ownerWme

  case owner of
    Just owner' -> do
      -- Add newResult to owner's local memory and propagate further.
      modifyTVar' (tokNccResults owner') (Set.insert newResult)
      writeTVar   (tokOwner newResult) owner
      deleteDescendentsOfTok env owner'

    Nothing ->
      -- We didn't find an appropriate owner token already in the Ncc
      -- node's memory, so we just stuff the result in our temporary
      -- buffer.
      modifyTVar' (partnerBuff partner) (Set.insert newResult)

-- | To find the appropriate owner token (into whose local memory we
-- should put the result tok), we must first figure out what pair
-- (ownersParent, ownersWme) would represent the owner. To do this we
-- start with the argument pair and walk up the right number of links to
-- find the pair that emerged from the join node for the condition
-- preceding the Ncc partner.
-- [Taken from the original Doorenbos thesis (with small changes)]
findOwnersPair :: Int -> ParentTok -> Maybe Wme -> (ParentTok, Maybe Wme)
findOwnersPair 0 parent wme = (parent, wme)
findOwnersPair i parent _   = findOwnersPair (i-1) parent' wme
  where
    wme = case parent of
      ParentTok t -> tokWme t
      Dtt         -> error "PANIC (4): ASKING FOR dtt.wme IS DISALLOWED."

    parent' = case parent of
      ParentTok t -> tokParent t
      Dtt         -> error "PANIC (5): ASKING FOR dtt.parent IS DISALLOWED."

findNccOwner :: Ncc -> ParentTok -> Maybe Wme -> STM (Maybe Tok)
findNccOwner Ncc { nccToks = index } parent wme =
  liftM (Map.lookup (OwnerKey parent wme)) (readTVar index)
{-# INLINE findNccOwner #-}

-- PRODUCTION NODES:

leftActivateProd :: Env -> Prod -> Tok -> STM ()
leftActivateProd env prod tok = do
  newTok <- makeAndInsertTok env (ParentTok tok) Nothing (ProdTokNode prod)
            (prodToks prod)

  -- Fire action
  let action = prodAction prod
  action (Actx env prod newTok (tokWmes newTok))

-- U/L ABSTRACTION, RE-LINKING

instance ToBool LeftUnlinked  where toBool (LeftUnlinked  b) = b
instance ToBool RightUnlinked where toBool (RightUnlinked b) = b

class IsLeftUnlinked  a   where isLeftUnlinked  :: a -> STM Bool
class IsRightUnlinked a   where isRightUnlinked :: a -> STM Bool
class LeftUnlink      a p where leftUnlink      :: a -> p -> STM ()
class RightUnlink     a   where rightUnlink     :: a -> Amem -> STM ()

relinkToAmem :: a -> STM ()
relinkToAmem = undefined

relinkToParent :: a -> STM ()
relinkToParent = undefined

-- DELETING TOKENS

deleteDescendentsOfTok :: Env -> Tok -> STM ()
deleteDescendentsOfTok = undefined
