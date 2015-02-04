{-# LANGUAGE    Trustworthy       #-}
{-# LANGUAGE    RankNTypes        #-}
{-# LANGUAGE    FlexibleInstances #-}
{-# OPTIONS_GHC -W -Wall          #-}
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
import           Data.Maybe (fromMaybe, isJust, fromJust, isNothing)
import qualified Data.Sequence as Seq
import           Kask.Control.Monad (forMM_, toListM, whenM)
import           Kask.Data.Sequence
  (removeFirstOccurence, insertBeforeFirstOccurence)

-- MISC. UTILS

-- | A monadic (in STM monad) version of Set.null.
nullTSet :: TVar (Set.HashSet a) -> STM Bool
nullTSet = liftM Set.null . readTVar
{-# INLINE nullTSet #-}

-- | A monadic (in STM monad) version of Data.Foldable.toList.
toListT :: Foldable f => TVar (f a) -> STM [a]
toListT = toListM . readTVar
{-# INLINE toListT #-}

toTSeqFront :: TVar (Seq.Seq a) -> a -> STM ()
toTSeqFront s = modifyTVar' s . (Seq.<|)
{-# INLINE toTSeqFront #-}

toTSeqEnd :: TVar (Seq.Seq a) -> a -> STM ()
toTSeqEnd s x = modifyTVar' s (Seq.|> x)
{-# INLINE toTSeqEnd #-}

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
  -- Env components.
  idState      <- newTVar 0
  constants    <- newTVar Map.empty
  variables    <- newTVar Map.empty
  wmes         <- newTVar Map.empty
  wmesByObj    <- newTVar Map.empty
  wmesByAttr   <- newTVar Map.empty
  wmesByVal    <- newTVar Map.empty
  amems        <- newTVar Map.empty
  prods        <- newTVar Set.empty

  dtnChildren  <- newTVar Map.empty

  -- Let's create Env.
  return Env { envIdState    = idState
             , envConstants  = constants
             , envVariables  = variables
             , envWmes       = wmes
             , envWmesByObj  = wmesByObj
             , envWmesByAttr = wmesByAttr
             , envWmesByVal  = wmesByVal
             , envAmems      = amems
             , envProds      = prods
             , envDtn        = Dtn dtnChildren }

feedEnvIndexes :: Env -> Wme -> STM ()
feedEnvIndexes
  Env     { envWmesByObj  = byObj
          , envWmesByAttr = byAttr
          , envWmesByVal  = byVal }
  wme@Wme { wmeObj        = o
          , wmeAttr       = a
          , wmeVal        = v } = do

    let w = Const wildcardConstant

    modifyTVar' byObj  (wmesIndexInsert o        wme)
    modifyTVar' byObj  (wmesIndexInsert (Obj w)  wme)

    modifyTVar' byAttr (wmesIndexInsert a        wme)
    modifyTVar' byAttr (wmesIndexInsert (Attr w) wme)

    modifyTVar' byVal  (wmesIndexInsert v        wme)
    modifyTVar' byVal  (wmesIndexInsert (Val w)  wme)
{-# INLINE feedEnvIndexes #-}

deleteFromEnvIndexes :: Env -> Wme -> STM ()
deleteFromEnvIndexes
  Env     { envWmesByObj  = byObj
          , envWmesByAttr = byAttr
          , envWmesByVal  = byVal}
  wme@Wme { wmeObj        = o
          , wmeAttr       = a
          , wmeVal        = v } = do

    let w = Const wildcardConstant

    modifyTVar' byObj  (wmesIndexDelete o        wme)
    modifyTVar' byObj  (wmesIndexDelete (Obj w)  wme)

    modifyTVar' byAttr (wmesIndexDelete a        wme)
    modifyTVar' byAttr (wmesIndexDelete (Attr w) wme)

    modifyTVar' byVal  (wmesIndexDelete v        wme)
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

class Symbolic a where
  -- | Interns and returns a Symbol for the name argument.
  internSymbol :: Env -> a -> STM Symbol

  -- | Only if there is an interned symbol of the given name,
  -- returns Just it, Nothing otherwise.
  internedSymbol :: Env -> a -> STM (Maybe Symbol)

instance Symbolic Symbol where
  -- We may simply return the argument here, because Constants and
  -- Variables once interned never expire (get un-interned). Otherwise
  -- we would have to intern the argument's name.
  internSymbol   _ = return
  internedSymbol _ = return . Just
  {-# INLINE internSymbol   #-}
  {-# INLINE internedSymbol #-}

instance Symbolic String where
  internSymbol env name = case symbolName name of
    EmptyConst     -> return (Const emptyConstant)
    EmptyVar       -> return (Var   emptyVariable)
    OneCharConst   -> liftM  Const (internConstant env name)
    MultiCharVar   -> liftM  Var   (internVariable env name)
    MultiCharConst -> liftM  Const (internConstant env name)

  internedSymbol env name = case symbolName name of
    EmptyConst     -> return $! Just (Const emptyConstant)
    EmptyVar       -> return $! Just (Var   emptyVariable)
    OneCharConst   -> internedConstant env name
    MultiCharVar   -> internedVariable env name
    MultiCharConst -> internedConstant env name
  {-# INLINE internSymbol   #-}
  {-# INLINE internedSymbol #-}

toObj :: (Symbolic o) => o -> Env -> STM Obj
toObj o env = liftM Obj (internSymbol env o)
{-# INLINE toObj #-}

toAttr :: (Symbolic a) => a -> Env -> STM Attr
toAttr a env = liftM Attr (internSymbol env a)
{-# INLINE toAttr #-}

toVal :: (Symbolic v) => v -> Env -> STM Val
toVal v env = liftM Val (internSymbol env v)
{-# INLINE toVal #-}

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

intern3 :: (Symbolic o, Symbolic a, Symbolic v)
        => Env -> o -> a -> v -> STM (Symbol, Symbol, Symbol)
intern3 env o a v = do
  o' <- internSymbol env o
  a' <- internSymbol env a
  v' <- internSymbol env v
  return (o', a', v')
{-# INLINE intern3 #-}

internFields :: (Symbolic o, Symbolic a, Symbolic v)
             => Env -> o -> a -> v -> STM (Obj, Attr, Val)
internFields env o a v = do
  (o', a', v') <- intern3 env o a v
  return (Obj o', Attr a', Val v')
{-# INLINE internFields #-}

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
  forMM_ (toListT (amemSuccessors amem)) $ \s -> case s of
    JoinSuccessor join -> rightActivateJoin env join wme
    NegSuccessor  neg  -> rightActivateNeg  env neg  wme

-- WMES

class AddWme e where
  -- | Adds a new fact represented by three fields and returns its Wme.
  -- When a Wme already exists in the system, does and returns Nothing.
  addWme :: (Symbolic a, Symbolic b, Symbolic c)
         => e -> a -> b -> c -> STM (Maybe Wme)

instance AddWme Env where
  addWme env o a v = do
    (o', a', v') <- intern3 env o a v
    let k = WmeKey (Obj o') (Attr a') (Val v')
    wmes <- readTVar (envWmes env)
    if Map.member k wmes
      then return Nothing -- Already present, do nothing.
      else do
        wme <- createWme env (Obj o') (Attr a') (Val v')

        -- Add wme to envWmes under k.
        writeTVar (envWmes env) $! Map.insert k wme wmes

        -- Add wme to env indexes (including wildcard key).
        feedEnvIndexes env wme

        -- Propagate wme into amems and return.
        feedAmems env wme (Obj o') (Attr a') (Val v')
        return (Just wme)

instance AddWme Actx where
  addWme actx = addWme (actxEnv actx)
  {-# INLINE addWme #-}

-- | Creates an empty Wme.
createWme :: Env -> Obj -> Attr -> Val -> STM Wme
createWme env o a v = do
  id'       <- genid env
  amems     <- newTVar []
  toks      <- newTVar Set.empty
  njResults <- newTVar Set.empty

  return Wme { wmeId             = id'
             , wmeObj            = o
             , wmeAttr           = a
             , wmeVal            = v
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

-- ACCESSING TOKEN WMES

class TokWmes a where tokWmes :: a -> [Maybe Wme]

instance TokWmes (Either Btok Ntok) where
  tokWmes (Left  btok) = tokWmes btok
  tokWmes (Right ntok) = tokWmes ntok

instance TokWmes JoinTok where
  tokWmes (Left  dtt ) = tokWmes dtt
  tokWmes (Right btok) = tokWmes btok

instance TokWmes (Either JoinTok Ntok) where
  tokWmes (Left  joinTok) = tokWmes joinTok
  tokWmes (Right ntok   ) = tokWmes ntok

instance TokWmes Dtt where
  tokWmes _ = []

instance TokWmes Btok where
  tokWmes Btok { btokWme = wme, btokParent = p } = Just wme : tokWmes p

instance TokWmes Ntok where
  tokWmes Ntok { ntokWme = wme, ntokParent = p } = wme : tokWmes p

instance TokWmes Ptok where
  tokWmes Ptok { ptokWme = wme, ptokParent = p } = wme : tokWmes p

class TokWme a where tokWme :: a -> Maybe Wme

instance TokWme WmeTok where
  tokWme tok = case tok of
    BmemWmeTok btok -> tokWme btok
    NegWmeTok  ntok -> tokWme ntok
    ProdWmeTok ptok -> tokWme ptok
  {-# INLINE tokWme #-}

instance TokWme Btok where
  tokWme Btok { btokWme = w } = Just w
  {-# INLINE tokWme #-}

instance TokWme Ntok where
  tokWme Ntok { ntokWme = w } = w
  {-# INLINE tokWme #-}

instance TokWme Ptok where
  tokWme Ptok { ptokWme = w } = w
  {-# INLINE tokWme #-}

-- BETA MEMORY

leftActivateBmem :: Env -> Bmem -> Either Dtt Btok -> Wme -> STM ()
leftActivateBmem env bmem tok wme = do
  -- Create new Btok.
  id'      <- genid env
  children <- newTVar Set.empty
  let newTok = Btok { btokId       = id'
                    , btokWme      = wme
                    , btokParent   = tok
                    , btokNode     = bmem
                    , btokChildren = children }

  -- Add newTok to bmem.toks.
  modifyTVar' (bmemToks bmem) (Set.insert newTok)

  -- Activate children Joins.
  forMM_ (toListT (bmemChildren bmem)) $ \join ->
    leftActivateJoin env join newTok

-- UNINDEXED JOIN

-- | Performs the join tests not using any kind of indexing. Useful
-- while right-activation, when the Amem passes a single Wme, so
-- there is no use of Amem indexing.
performJoinTests :: [JoinTest] -> Either Btok Ntok -> Wme -> Bool
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
matchingAmemWmes :: [JoinTest] -> Either Btok Ntok -> Amem -> STM [Wme]
matchingAmemWmes [] _ amem = toListT (amemWmes amem) -- No tests, take all Wmes.
matchingAmemWmes tests tok amem = -- At least one test specified.
  toListM (foldr (liftM2 Set.intersection) s sets)
  where
    (s:sets) = map (amemWmesForTest (tokWmes tok) amem) tests
{-# INLINE matchingAmemWmes #-}

amemWmesForTest :: [Maybe Wme] -> Amem -> JoinTest -> STM (Set.HashSet Wme)
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

amemWmesForIndex :: (Hashable a, Eq a) =>
                    a -> TVar (WmesIndex a) -> STM (Set.HashSet Wme)
amemWmesForIndex k index =
  liftM (Map.lookupDefault Set.empty k) (readTVar index)
{-# INLINE amemWmesForIndex #-}

-- JOIN NODES

leftActivateJoin :: Env -> Join -> Btok -> STM ()
leftActivateJoin env join btok = case joinParent join of
  Left  _    -> leftActivateDummyJoin env join      btok
  Right bmem -> leftActivateStdJoin   env join bmem btok
{-# INLINE leftActivateJoin #-}

leftActivateDummyJoin :: Env -> Join -> Btok -> STM ()
leftActivateDummyJoin env join btok = do
  -- The join.parent is never empty (it contains a Dtt), so join is
  -- never right-unlinked. It also makes no sense to left-unlink it,
  -- cause it never undergoes any left activations (from Dtn) anyway.
  let amem = joinAmem join
  isAmemEmpty <- nullTSet (amemWmes amem)

  unless isAmemEmpty $ do
    children <- joinChildren join
    -- Only when we have children to activate ...
    unless (nullJoinChildren children) $ do
      -- ... take all Wmes from amem (Dtt from above matches all of them)
      wmes <- toListT (amemWmes amem)
      -- and iterate all wmes over all children left-activating:
      forM_ wmes $ \wme -> leftActivateJoinChildren
                           env children (Right btok) (Left (Right btok)) wme

leftActivateStdJoin :: Env -> Join -> Bmem -> Btok -> STM()
leftActivateStdJoin env join parent btok = do
  let amem = joinAmem join
  isAmemEmpty <- nullTSet (amemWmes amem)

  -- When join.parent just became non-empty.
  whenM (isRightUnlinked (JoinSuccessor join)) $ do
    relinkToAmem (JoinSuccessor join)
    when isAmemEmpty $ leftUnlink join parent

  unless isAmemEmpty $ do
    children <- joinChildren join
    -- Only when we have children to activate ...
    unless (nullJoinChildren children) $ do
      -- ... take matching Wmes from Amem indexes
      wmes <- matchingAmemWmes (joinTests join) (Left btok) amem
      -- and iterate all wmes over all children left-activating:
      forM_ wmes $ \wme -> leftActivateJoinChildren
                           env children (Right btok) (Left (Right btok)) wme

type JoinChildren = (Maybe Bmem, [Neg], [Prod])

joinChildren :: Join -> STM JoinChildren
joinChildren join = do
  bmem  <- readTVar (joinBmem  join)
  negs  <- readTVar (joinNegs  join)
  prods <- readTVar (joinProds join)
  return (bmem, Map.elems negs, toList prods)
{-# INLINE joinChildren #-}

nullJoinChildren :: JoinChildren -> Bool
nullJoinChildren (bmem, negs, prods) =
  isNothing bmem && null negs  && null prods
{-# INLINE nullJoinChildren #-}

leftActivateJoinChildren :: Env -> JoinChildren
                            -> Either Dtt Btok     -- ^ For Bmem activation.
                            -> Either JoinTok Ntok -- ^ For Neg/Prod activation.
                            -> Wme
                            -> STM ()
leftActivateJoinChildren env (bmem, negs, prods) rtok ltok wme = do
  when (isJust bmem)  $  leftActivateBmem env (fromJust bmem) rtok       wme
  forM_ negs  $ \neg  -> leftActivateNeg  env neg             ltok (Just wme)
  forM_ prods $ \prod -> leftActivateProd env prod            ltok (Just wme)
{-# INLINE leftActivateJoinChildren #-}

rightActivateJoin :: Env -> Join -> Wme -> STM ()
rightActivateJoin env join wme = case joinParent join of
  Left  _    -> rightActivateDummyJoin env join      wme
  Right bmem -> rightActivateStdJoin   env join bmem wme
{-# INLINE rightActivateJoin #-}

rightActivateDummyJoin :: Env -> Join -> Wme -> STM ()
rightActivateDummyJoin env join wme = do
  -- Like in the case of left activation, we skip any U/L proceeding
  -- here. Dtt always matches any Wme, so there is no need to perform
  -- any join tests. We simply activate children with Dtt and wme.
  children <- joinChildren join
  leftActivateJoinChildren env children (Left Dtt) (Left (Left Dtt)) wme
{-# INLINE rightActivateDummyJoin #-}

rightActivateStdJoin :: Env -> Join -> Bmem -> Wme -> STM ()
rightActivateStdJoin env join parent wme = do
  parentToks <- readTVar (bmemToks parent)
  let isParentEmpty = Set.null parentToks

  whenM (isLeftUnlinked join) $ do -- When join.amem just became non-empty.
    relinkToParent join parent
    when isParentEmpty (rightUnlink (JoinSuccessor join))

  -- Only when parent has some Toks inside,
  unless isParentEmpty $ do
    children <- joinChildren join
    -- Only when there are some children...
    unless (nullJoinChildren children) $
      -- Iterate over parent.toks ...
      forM_ (toList parentToks) $ \btok ->
        when (performJoinTests (joinTests join) (Left btok) wme) $
          -- ... and JoinChildren performing left activation.
          leftActivateJoinChildren env children
                                   (Right btok) (Left (Right btok)) wme

-- NEGATION NODES

leftActivateNeg :: Env -> Neg -> Either JoinTok Ntok -> Maybe Wme -> STM ()
leftActivateNeg env neg tok wme = do
  toks <- readTVar (negToks neg)
  whenM (isRightUnlinked (NegSuccessor neg)) $
    -- The right-unlinking status above must be checked because a
    -- negative node is not right unlinked on creation.
    when (Set.null toks) $ relinkToAmem (NegSuccessor neg)

  -- Build a new token and store it just like a Bmem would.
  id'          <- genid env
  newChildren  <- newTVar Set.empty
  newNjResults <- newTVar Set.empty
  let newTok = Ntok { ntokId             = id'
                    , ntokWme            = wme
                    , ntokParent         = tok
                    , ntokNode           = neg
                    , ntokChildren       = newChildren
                    , ntokNegJoinResults = newNjResults }

  writeTVar (negToks neg) (Set.insert newTok toks)

  let amem = negAmem neg
  isAmemEmpty <- nullTSet (amemWmes amem)

  -- Compute the join results (using amem indexes).
  unless isAmemEmpty $ do
    wmes <- matchingAmemWmes (negTests neg) (Right newTok) amem
    forM_ wmes $ \w -> do
      let jr = NegJoinResult newTok w
      modifyTVar' (ntokNegJoinResults newTok) (Set.insert jr)
      modifyTVar' (wmeNegJoinResults  w)      (Set.insert jr)
      -- In the original Doorenbos pseudo-code there was a bug - wme
      -- was used instead of w in the 3 lines above.

  -- If join results are empty, then inform children.
  whenM (nullTSet (ntokNegJoinResults newTok)) $ do
    children <- negChildren neg
    unless (nullNegChildren children) $
      leftActivateNegChildren env children (Right newTok) Nothing

type NegChildren = ([Neg], [Prod])

negChildren :: Neg -> STM NegChildren
negChildren neg = do
  negs  <- readTVar (negNegs  neg)
  prods <- readTVar (negProds neg)
  return (Map.elems negs, toList prods)
{-# INLINE negChildren #-}

nullNegChildren :: NegChildren -> Bool
nullNegChildren (negs, prods) = null negs  && null prods
{-# INLINE nullNegChildren #-}

leftActivateNegChildren :: Env -> NegChildren
                        -> Either JoinTok Ntok -> Maybe Wme -> STM ()
leftActivateNegChildren env (negs, prods) tok wme = do
  forM_ negs  $ \neg  -> leftActivateNeg  env neg  tok wme
  forM_ prods $ \prod -> leftActivateProd env prod tok wme
{-# INLINE leftActivateNegChildren #-}

rightActivateNeg :: Env -> Neg -> Wme -> STM ()
rightActivateNeg env neg wme =
  forMM_ (toListT (negToks neg)) $ \tok ->
    when (performJoinTests (negTests neg) (Right tok) wme) $ do
      whenM (nullTSet (ntokNegJoinResults tok)) $
        deleteDescendentsOfTok env (NegWmeTok tok)

      let jr = NegJoinResult tok wme
      -- Insert jr into tok.(neg)join-results.
      modifyTVar' (ntokNegJoinResults tok) (Set.insert jr)
      -- Insert jr into wme.neg-join-results.
      modifyTVar' (wmeNegJoinResults  wme) (Set.insert jr)

-- PRODUCTION NODES

leftActivateProd :: Env -> Prod -> Either JoinTok Ntok -> Maybe Wme -> STM ()
leftActivateProd env prod tok wme = do
  -- Create new Ptok.
  id' <- genid env
  let newTok = Ptok { ptokId     = id'
                    , ptokWme    = wme
                    , ptokParent = tok
                    , ptokNode   = prod }

  modifyTVar' (prodToks prod) (Set.insert newTok)

  -- Fire action.
  let action = prodAction prod
  action (Actx env prod newTok (tokWmes newTok))

-- LEFT U/L (Joins ONLY)

isLeftUnlinked :: Join -> STM Bool
isLeftUnlinked = readTVar . joinLeftUnlinked
{-# INLINE isLeftUnlinked #-}

leftUnlink :: Join -> Bmem -> STM ()
leftUnlink join parent = do
  modifyTVar' (bmemChildren     parent) (Set.delete join)
  writeTVar   (joinLeftUnlinked join  ) True
{-# INLINE leftUnlink #-}

relinkToParent :: Join -> Bmem -> STM ()
relinkToParent join parent = do
  modifyTVar' (bmemChildren     parent) (Set.insert join)
  writeTVar   (joinLeftUnlinked join  ) False
{-# INLINE relinkToParent #-}

-- RIGHT U/L (Joins AND Negs - AmemSuccessors)

isRightUnlinked :: AmemSuccessor -> STM Bool
isRightUnlinked = readTVar . rightUnlinked
{-# INLINE isRightUnlinked #-}

rightUnlink :: AmemSuccessor -> STM ()
rightUnlink node = do
  modifyTVar' (amemSuccessors (nodeAmem node)) (removeFirstOccurence node)
  writeTVar   (rightUnlinked  node) True
{-# INLINE rightUnlink #-}

relinkToAmem :: AmemSuccessor -> STM ()
relinkToAmem node = do
  let amem' = nodeAmem node
  ancestorLookup <- relinkAncestor node
  case ancestorLookup of
    Just ancestor ->
      -- Insert node into node.amem.successors immediately before
      -- ancestor.
      modifyTVar' (amemSuccessors amem')
        (node `insertBeforeFirstOccurence` ancestor)

    -- Insert node at the tail of node.amem.successors.
    Nothing -> toTSeqEnd (amemSuccessors amem') node

  writeTVar (rightUnlinked node) False
{-# INLINE relinkToAmem #-}

-- | The goal of this loop is to find the nearest right linked
-- ancestor with the same Amem.
relinkAncestor :: AmemSuccessor -> STM (Maybe AmemSuccessor)
relinkAncestor node = do
  let possibleAncestor = nearestAncestor node
  case possibleAncestor of
    Nothing       -> return Nothing
    Just ancestor -> do
      rightUnlinked' <- isRightUnlinked ancestor
      if rightUnlinked'
        then relinkAncestor ancestor
        else return possibleAncestor

successorProp :: (Join -> a) -> (Neg -> a) -> AmemSuccessor -> a
successorProp f1 f2 node = case node of
  JoinSuccessor join -> f1 join
  NegSuccessor  neg  -> f2 neg
{-# INLINE successorProp #-}

rightUnlinked :: AmemSuccessor -> TVar Bool
rightUnlinked  = successorProp joinRightUnlinked negRightUnlinked
{-# INLINE rightUnlinked #-}

nearestAncestor :: AmemSuccessor -> Maybe AmemSuccessor
nearestAncestor = successorProp (liftM JoinSuccessor . joinNearestAncestor)
                                negNearestAncestor
{-# INLINE nearestAncestor #-}

nodeAmem :: AmemSuccessor -> Amem
nodeAmem = successorProp joinAmem negAmem
{-# INLINE nodeAmem #-}

-- REMOVING WMES

class RemoveWme e where
  -- | Removes the fact described by 3 symbols. Returns True on success
  -- and False when the fact was not present in the system.
  removeWme :: (Symbolic a, Symbolic b, Symbolic c)
            => e -> a -> b -> c -> STM Bool

instance RemoveWme Env where
  removeWme env o a v = do
    o' <- internedSymbol env o
    a' <- internedSymbol env a
    v' <- internedSymbol env v

    if isJust o' && isJust a' && isJust v'
      then removeWmeImpl env
                         (Obj  (fromJust o'))
                         (Attr (fromJust a'))
                         (Val  (fromJust v'))

      -- At least 1 of the names didn't have a corresponding interned
      -- symbol, the wme can't exist.
      else return False

instance RemoveWme Actx where
  removeWme actx = removeWme (actxEnv actx)
  {-# INLINE removeWme #-}

removeWmeImpl :: Env -> Obj -> Attr -> Val -> STM Bool
removeWmeImpl env o a v = do
  wmes <- readTVar (envWmes env)
  let k = WmeKey o a v
  case Map.lookup k wmes of
    Nothing -> return False
    Just wme -> do
      -- Remove from Working Memory (Env registry and indexes)
      writeTVar (envWmes env) $! Map.delete k wmes
      deleteFromEnvIndexes env wme
      -- ... and propagate down the network.
      propagateWmeRemoval env wme o a v
      return True
{-# INLINE removeWmeImpl #-}

propagateWmeRemoval :: Env -> Wme -> Obj -> Attr -> Val -> STM ()
propagateWmeRemoval env wme o a v = do
  -- For every amem this wme belongs to ...
  forMM_ (readTVar (wmeAmems wme)) $ \amem -> do
    -- ... remove wme from amem indexes.
    modifyTVar' (amemWmesByObj  amem) (wmesIndexDelete o wme)
    modifyTVar' (amemWmesByAttr amem) (wmesIndexDelete a wme)
    modifyTVar' (amemWmesByVal  amem) (wmesIndexDelete v wme)
    wmes <- readTVar (amemWmes amem)
    let updatedWmes = Set.delete wme wmes
    writeTVar (amemWmes amem) updatedWmes

    when (Set.null updatedWmes) $ -- Amem just became empty, so ...
      -- ... left-unlink all Join successors.
      forMM_ (toListT (amemSuccessors amem)) $ \s ->
        case s of
          JoinSuccessor join -> case joinParent join of
            Right bmem -> leftUnlink join bmem
            Left  _    -> return () -- Do not unlink from Dtn.

          NegSuccessor  _    -> return ()

  -- Delete all tokens wme is in. We remove every token from it's
  -- parent token but avoid removing from wme.
  forMM_ (toListT (wmeToks wme)) $ \tok ->
    deleteTokAndDescendents env tok RemoveFromParent DontRemoveFromWme

  -- For every jr in wme.negative-join-results ...
  forMM_ (toListT (wmeNegJoinResults wme)) $ \jr -> do
    -- ... remove jr from jr.owner.negative-join-results.
    let owner = njrOwner jr
    jresults <- readTVar (ntokNegJoinResults owner)
    let updatedJresults = Set.delete jr jresults
    writeTVar (ntokNegJoinResults owner) updatedJresults

    -- If jr.owner.negative-join-results is nil.
    when (Set.null updatedJresults) $ do
      children <- negChildren (ntokNode owner)
      unless (nullNegChildren children) $
        leftActivateNegChildren env children (Right owner) Nothing
{-# INLINE propagateWmeRemoval #-}

-- DELETING TOKS

data TokTokPolicy = RemoveFromParent | DontRemoveFromParent deriving Eq
data TokWmePolicy = RemoveFromWme    | DontRemoveFromWme    deriving Eq

-- | Deletes the descendents of the passed token.
deleteDescendentsOfTok :: Env -> WmeTok -> STM ()
deleteDescendentsOfTok env tok = case tok of
  BmemWmeTok btok -> do
    children <- readTVar (btokChildren btok)
    unless (Set.null children) $ do
      writeTVar (btokChildren btok) Set.empty
      forM_ (toList children) $ \child ->
        deleteTokAndDescendents env child DontRemoveFromParent RemoveFromWme

  NegWmeTok ntok -> do
    children <- readTVar (ntokChildren ntok)
    unless (Set.null children) $ do
      writeTVar (ntokChildren ntok) Set.empty
      forM_ (toList children) $ \child -> do
        let c = case child of
              Left  nt -> NegWmeTok  nt
              Right pt -> ProdWmeTok pt
        deleteTokAndDescendents env c DontRemoveFromParent RemoveFromWme

  ProdWmeTok _ -> return () -- No children, do nothing.

-- | Deletes the token and it's descendents.
deleteTokAndDescendents :: Env -> WmeTok -> TokTokPolicy -> TokWmePolicy -> STM ()
deleteTokAndDescendents env tok tokPolicy wmePolicy = do
  deleteDescendentsOfTok env tok
  removeTokFromItsNode   tok

  when (wmePolicy == RemoveFromWme) $ case tokWme tok of
    Nothing -> return ()
    Just w  -> modifyTVar' (wmeToks w) (Set.delete tok)

  when (tokPolicy == RemoveFromParent) $ removeTokFromItsParent tok

  -- Node-specific deletion.
  case tok of
    BmemWmeTok btok -> deleteBtok     btok
    NegWmeTok  ntok -> deleteNtok     ntok
    ProdWmeTok ptok -> deletePtok env ptok

removeTokFromItsNode :: WmeTok -> STM ()
removeTokFromItsNode tok = case tok of
  BmemWmeTok btok -> modifyTVar' (bmemToks (btokNode btok)) (Set.delete btok)
  NegWmeTok  ntok -> modifyTVar' (negToks  (ntokNode ntok)) (Set.delete ntok)
  ProdWmeTok ptok -> modifyTVar' (prodToks (ptokNode ptok)) (Set.delete ptok)
{-# INLINE removeTokFromItsNode #-}

class RemoveTokFromItsParent a where removeTokFromItsParent :: a -> STM ()

instance RemoveTokFromItsParent WmeTok where
  removeTokFromItsParent (BmemWmeTok btok) = removeTokFromItsParent btok
  removeTokFromItsParent (NegWmeTok  ntok) = removeTokFromItsParent ntok
  removeTokFromItsParent (ProdWmeTok ptok) = removeTokFromItsParent ptok
  {-# INLINE removeTokFromItsParent #-}

instance RemoveTokFromItsParent Btok where
  removeTokFromItsParent btok = case btokParent btok of
    Left  _      -> return () -- No removal from Dtt.
    Right parent -> modifyTVar' (btokChildren parent)
                    (Set.delete (BmemWmeTok btok))
  {-# INLINE removeTokFromItsParent #-}

instance RemoveTokFromItsParent Ntok where
  removeTokFromItsParent ntok = case ntokParent ntok of
    Left  joinTok -> case joinTok of
      Left  _      -> return () -- No removal from Dtt.
      Right parent -> modifyTVar' (btokChildren parent)
                      (Set.delete (NegWmeTok ntok))
    Right parent  -> modifyTVar' (ntokChildren parent)
                     (Set.delete (Left ntok))
  {-# INLINE removeTokFromItsParent #-}

instance RemoveTokFromItsParent Ptok where
  removeTokFromItsParent ptok = case ptokParent ptok of
    Left  joinTok -> case joinTok of
      Left  _      -> return () -- No removal from Dtt.
      Right parent -> modifyTVar' (btokChildren parent)
                      (Set.delete (ProdWmeTok ptok))
    Right parent  -> modifyTVar' (ntokChildren parent)
                     (Set.delete (Right ptok))
  {-# INLINE removeTokFromItsParent #-}

deleteBtok :: Btok -> STM ()
deleteBtok Btok { btokNode = bmem }  =
  whenM (nullTSet (bmemToks bmem)) $ -- No items in here, so ...
    forMM_ (toListT (bmemChildren bmem)) $ \join ->
      -- ... let's right unlink children.
      rightUnlink (JoinSuccessor join)
{-# INLINE deleteBtok #-}

deleteNtok :: Ntok -> STM ()
deleteNtok ntok = do
  let neg = ntokNode ntok
  whenM (nullTSet (negToks neg)) $ rightUnlink (NegSuccessor neg)

  -- For jr in tok.(neg)-join-results ...
  forMM_ (toListT (ntokNegJoinResults ntok)) $ \jr ->
    -- ... remove jr from jr.wme.negative-join-results.
    modifyTVar' (wmeNegJoinResults (njrWme jr)) (Set.delete jr)
{-# INLINE deleteNtok #-}

deletePtok :: Env -> Ptok -> STM ()
deletePtok env ptok = case prodRevokeAction (ptokNode ptok) of
  -- Let's just fire a proper action (if present).
  Nothing     -> return ()
  Just action -> action (Actx env (ptokNode ptok) ptok (tokWmes ptok))
{-# INLINE deletePtok #-}
