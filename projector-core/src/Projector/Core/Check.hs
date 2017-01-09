{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE UndecidableInstances #-}
module Projector.Core.Check where {- (
    typeCheck
  , typeTree
  ) where -}


import           Control.Applicative.Lift (Errors, Lift (..), runErrors)
import           Control.Monad.ST (ST, runST)
import           Control.Monad.Trans.Class (MonadTrans(..))
import           Control.Monad.Trans.State.Strict (State, runState, gets, modify')

import           Data.DList (DList)
import qualified Data.DList as D
import           Data.Functor.Constant (Constant(..))
import qualified Data.List as L
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Set (Set)
import qualified Data.Set as S
import           Data.STRef (STRef)
import qualified Data.STRef as ST
import qualified Data.UnionFind.ST as UF

import           P

import           Projector.Core.Syntax
import           Projector.Core.Type

import           X.Control.Monad.Trans.Either


data TypeError l a
  = UnificationError (IType l a) (IType l a)
  | FreeVariable Name a
  | UndeclaredType TypeName a
  | BadConstructorName Constructor TypeName (Decl l) a
  | BadConstructorArity Constructor (Decl l) Int a
  | BadPatternArity Constructor (Type l) Int Int a
  | BadPatternConstructor Constructor a
  | NonExhaustiveCase (Expr l a) (Type l) a
  | InferenceError a

deriving instance (Eq l, Eq (Value l), Eq a) => Eq (TypeError l a)
deriving instance (Show l, Show (Value l), Show a) => Show (TypeError l a)
deriving instance (Ord l, Ord (Value l), Ord a) => Ord (TypeError l a)


typeCheck :: Ground l => Ord a => TypeDecls l -> Expr l a -> Either [TypeError l a] (Type l)
typeCheck decls =
  fmap extractType . typeTree decls

typeTree ::
     Ground l
  => Ord a
  => TypeDecls l
  -> Expr l a
  -> Either [TypeError l a] (Expr l (Type l, a))
typeTree decls expr = do
  (expr', constraints) <- generateConstraints decls expr
  subs <- solveConstraints constraints
  let subbed = substitute expr' subs
  sequenceErrors (fmap (\(i, a) -> fmap (,a) (first pure (lowerIType i))) subbed)

-- -----------------------------------------------------------------------------
-- Types

-- | 'IType l a' is a fixpoint of 'IVar a (TypeF l)'.
--
-- i.e. regular types, recursively extended with annotations and an
-- extra constructor, 'IDunno', representing fresh type/unification variables.
newtype IType l a = I (IVar a (TypeF l (IType l a)))
  deriving (Eq, Ord, Show)

-- | 'IVar' is an open functor equivalent to an annotated 'Either Int'.
data IVar ann a
  = IDunno ann Int
  | IAm ann a
  deriving (Eq, Ord, Show, Functor, Foldable, Traversable)

-- | Lift a known type into an 'IType', with an annotation.
hoistType :: a -> Type l -> IType l a
hoistType a (Type ty) =
  I (IAm a (fmap (hoistType a) ty))

-- | Assert that we have a monotype. Returns 'InferenceError' if we
-- encounter a unification variable.
lowerIType :: IType l a -> Either (TypeError l a) (Type l)
lowerIType (I v) =
  case v of
    IDunno a _ ->
      Left (InferenceError a)
    IAm _ ty ->
      fmap Type (traverse lowerIType ty)

typeVar :: IType l a -> Maybe Int
typeVar ty =
  case ty of
    I (IDunno _ x) ->
      pure x
    I (IAm _ _) ->
      Nothing

-- -----------------------------------------------------------------------------
-- Monad stack

-- | 'Check' permits multiple errors via 'EitherT', lexically-scoped
-- state via 'ReaderT', and global accumulating state via 'State'.
newtype Check l a b = Check {
    unCheck :: EitherT (DList (TypeError l a)) (State (SolverState l a)) b
  } deriving (Functor, Applicative, Monad)

runCheck :: Check l a b -> Either [TypeError l a] (b, SolverState l a)
runCheck f =
    unCheck f
  & runEitherT
  & flip runState initialSolverState
  & \(e, st) -> fmap (,st) (first D.toList e)

data SolverState l a = SolverState {
    sConstraints :: DList (Constraint l a)
  , sAssumptions :: Map Name (Set (IType l a))
  , sSupply :: NameSupply
  } deriving (Eq, Ord, Show)

initialSolverState :: SolverState l a
initialSolverState =
  SolverState {
      sConstraints = mempty
    , sAssumptions = mempty
    , sSupply = emptyNameSupply
    }

throwError :: TypeError l a -> Check l a b
throwError =
  Check . left . D.singleton

-- -----------------------------------------------------------------------------
-- Name supply

-- | Supply of fresh unification variables.
newtype NameSupply = NameSupply { nextVar :: Int }
  deriving (Eq, Ord, Show)

emptyNameSupply :: NameSupply
emptyNameSupply =
  NameSupply 0

-- | Grab a fresh type variable.
freshTypeVar :: a -> Check l a (IType l a)
freshTypeVar a =
  Check . lift $ do
    v <- gets (nextVar . sSupply)
    modify' (\s -> s { sSupply = NameSupply (v + 1) })
    return (I (IDunno a v))

-- -----------------------------------------------------------------------------
-- Constraints

data Constraint l a
  = Equal (IType l a) (IType l a)
  deriving (Eq, Ord, Show)

-- | Record a new constraint.
addConstraint :: Ground l => Constraint l a -> Check l a ()
addConstraint c =
  Check . lift $
    modify' (\s -> s { sConstraints = D.snoc (sConstraints s) c })

-- -----------------------------------------------------------------------------
-- Assumptions

-- | Add an assumed type for some variable we've encountered.
addAssumption :: Ground l => Ord a => Name -> IType l a -> Check l a ()
addAssumption n ty =
  Check . lift $
    modify' (\s -> s { sAssumptions = M.insertWith (<>) n (S.singleton ty) (sAssumptions s)})

-- | Clobber the assumption set for some variable.
setAssumptions :: Ground l => Ord a => Name -> Set (IType l a) -> Check l a ()
setAssumptions n assums =
  Check . lift $
    modify' (\s -> s { sAssumptions = M.insert n assums (sAssumptions s)})

-- | Delete all assumptions for some variable.
--
-- This is called when leaving the lexical scope in which the variable was bound.
deleteAssumptions :: Ground l => Name -> Check l a ()
deleteAssumptions n =
  Check . lift $
    modify' (\s -> s { sAssumptions = M.delete n (sAssumptions s)})

-- | Look up all assumptions for a given name. Returns the empty set if there are none.
lookupAssumptions :: Ground l => Ord a => Name -> Check l a (Set (IType l a))
lookupAssumptions n =
  Check . lift $
    fmap (fromMaybe mempty) (gets (M.lookup n . sAssumptions))

-- | Run some continuation with lexically-scoped assumptions.
-- This is sorta like 'local', but we need to keep changes to other keys in the map.
withBindings :: Ground l => Traversable f => Ord a => f Name -> Check l a b -> Check l a (Map Name (Set (IType l a)), b)
withBindings xs k = do
  old <- fmap (M.fromList . toList) . for xs $ \n -> do
    as <- lookupAssumptions n
    deleteAssumptions n
    pure (n, as)
  res <- k
  new <- fmap (M.fromList . toList) . for xs $ \n -> do
    as <- lookupAssumptions n
    setAssumptions n (fromMaybe mempty (M.lookup n old))
    pure (n, as)
  pure (new, res)

withBinding :: Ground l => Ord a => Name -> Check l a b -> Check l a (Set (IType l a), b)
withBinding x k = do
  (as, b) <- withBindings [x] k
  pure (fromMaybe mempty (M.lookup x as), b)

-- -----------------------------------------------------------------------------
-- Constraint generation

generateConstraints :: Ground l => Ord a => TypeDecls l -> Expr l a -> Either [TypeError l a] (Expr l (IType l a, a), [Constraint l a])
generateConstraints decls expr = do
  (fmap (second (D.toList . sConstraints)) (runCheck (generateConstraints' decls expr)))

generateConstraints' :: Ground l => Ord a => TypeDecls l -> Expr l a -> Check l a (Expr l (IType l a, a))
generateConstraints' decls expr =
  case expr of
    ELit a v ->
      -- We know the type of literals instantly.
      let ty = TLit (typeOf v)
      in pure (ELit (hoistType a ty, a) v)

    EVar a v -> do
      -- We introduce a new type variable representing the type of this expression.
      -- Add it to the assumption set.
      t <- freshTypeVar a
      addAssumption v t
      pure (EVar (t, a) v)

    ELam a n ta e -> do
      -- Proceed bottom-up, generating constraints for 'e'.
      -- Gather the assumed types of 'n', and constrain them to be the known (annotated) type.
      -- This expression's type is an arrow from the known type to the inferred type of 'e'.
      (as, e') <- withBinding n (generateConstraints' decls e)
      for_ (S.toList as) (addConstraint . Equal (hoistType a ta))
      let ty = I (IAm a (TArrowF (hoistType a ta) (extractType e')))
      pure (ELam (ty, a) n ta e')

    EApp a f g -> do
      -- Proceed bottom-up, generating constraints for 'f' and 'g'.
      -- Introduce a new type variable for the result of the expression.
      -- Constrain 'f' to be an arrow from the type of 'g' to this type.
      f' <- generateConstraints' decls f
      g' <- generateConstraints' decls g
      t <- freshTypeVar a
      addConstraint (Equal (I (IAm a (TArrowF (extractType g') t))) (extractType f'))
      pure (EApp (t, a) f' g')

    EList a te es -> do
      -- Proceed bottom-up, inferring types for each expression in the list.
      -- Constrain each type to be the annotated 'ty'.
      es' <- for es (generateConstraints' decls)
      for_ es' (addConstraint . Equal (hoistType a te) . extractType)
      let ty = I (IAm a (TListF (hoistType a te)))
      pure (EList (ty, a) te es')

    ECon a c tn es ->
      case lookupType tn decls of
        Just ty@(DVariant cns) -> do
          -- Look up the constructor, check its arity, and introduce
          -- constraints for each of its subterms, for which we expect certain types.
          ts <- maybe (throwError (BadConstructorName c tn ty a)) pure (L.lookup c cns)
          unless (length ts == length es) (throwError (BadConstructorArity c ty (length es) a))
          es' <- for es (generateConstraints' decls)
          for_ (L.zip (fmap (hoistType a) ts) (fmap extractType es'))
            (\(expected, inferred) -> addConstraint (Equal expected inferred))
          let ty' = I (IAm a (TVarF tn))
          pure (ECon (ty', a) c tn es')

        Nothing ->
          throwError (UndeclaredType tn a)

    ECase a e pes -> do
      -- The body of the case expression should be the same type for each branch.
      -- We introduce a new unification variable for that type.
      -- Patterns introduce new constraints and bindings, managed in 'patternConstraints'.
      e' <- generateConstraints' decls e
      ty <- freshTypeVar a
      pes' <- for pes $ \(pat, pe) -> do
        let bnds = patternBinds pat
        (_, res) <- withBindings (S.toList bnds) $ do
          -- Order matters here, patCons consumes the assumptions from genCons.
          pe' <- generateConstraints' decls pe
          pat' <- patternConstraints decls (extractType e') pat
          addConstraint (Equal ty (extractType pe'))
          pure (pat', pe')
        pure res
      pure (ECase (ty, a) e' pes')

    EForeign a n ty -> do
      -- We know the type of foreign expressions immediately, because they're annotated.
      pure (EForeign (hoistType a ty, a) n ty)

-- | Patterns are binding sites that also introduce lots of new constraints.
patternConstraints ::
     Ground l
  => Ord a
  => TypeDecls l
  -> IType l a
  -> Pattern a
  -> Check l a (Pattern (IType l a, a))
patternConstraints decls ty pat =
  case pat of
    PVar a x -> do
      as <- lookupAssumptions x
      for_ as (addConstraint . Equal ty)
      pure (PVar (ty, a) x)

    PCon a c pats ->
      case lookupConstructor c decls of
        Just (tn, ts) -> do
          unless (length ts == length pats)
            (throwError (BadPatternArity c (TVar tn) (length ts) (length pats) a))
          let ty' = I (IAm a (TVarF tn))
          addConstraint (Equal ty' ty)
          pats' <- for (L.zip (fmap (hoistType a) ts) pats) (uncurry (patternConstraints decls))
          pure (PCon (ty', a) c pats')

        Nothing ->
          throwError (BadPatternConstructor c a)

extractType :: Expr l (c, a) -> c
extractType =
  fst . extractAnnotation

-- -----------------------------------------------------------------------------
-- Constraint solving

newtype Substitutions l a
  = Substitutions { unSubstitutions :: Map Int (IType l a) }

substitute :: Ground l => Expr l (IType l a, a) -> Substitutions l a -> Expr l (IType l a, a)
substitute expr subs =
  with expr $ \(ty, a) ->
    (substituteType subs ty, a)

substituteType :: Ground l => Substitutions l a -> IType l a -> IType l a
substituteType subs ty =
  case ty of
    I (IDunno _ x) ->
      maybe ty (substituteType subs) (M.lookup x (unSubstitutions subs))

    I (IAm a (TArrowF t1 t2)) ->
      I (IAm a (TArrowF (substituteType subs t1) (substituteType subs t2)))

    I (IAm a (TListF t)) ->
      I (IAm a (TListF (substituteType subs t)))

    I (IAm _ (TLitF _)) ->
      ty

    I (IAm _ (TVarF _)) ->
      ty
{-# INLINE substituteType #-}

mostGeneralUnifierST ::
     Ground l
  => STRef s (Map Int (UF.Point s (IType l a)))
  -> IType l a
  -> IType l a
  -> ST s (Either (TypeError l a) ())
mostGeneralUnifierST points t1 t2 =
  runEitherT (mguST points t1 t2)

mguST ::
     Ground l
  => STRef s (Map Int (UF.Point s (IType l a)))
  -> IType l a
  -> IType l a
  -> EitherT (TypeError l a) (ST s) ()
mguST points t1 t2 =
  case (t1, t2) of
    (I (IDunno _ x), _) -> do
      mty <- lift (getRepr points x)
      case mty of
        Just ty ->
          if typeVar ty == Just x then lift (union points t1 t2)
          else mguST points ty t2
        Nothing ->
          lift (union points t1 t2)

    (_, I (IDunno _ x)) -> do
      mty <- lift (getRepr points x)
      case mty of
        Just ty ->
          if typeVar ty == Just x then lift (union points t2 t1)
          else mguST points t1 ty
        Nothing ->
          lift (union points t2 t1)

    (I (IAm _ (TVarF x)), I (IAm _ (TVarF y))) ->
      unless (x == y) (left (UnificationError t1 t2))

    (I (IAm _ (TLitF x)), I (IAm _ (TLitF y))) ->
      unless (x == y) (left (UnificationError t1 t2))

    (I (IAm _ (TArrowF f g)), I (IAm _ (TArrowF h i))) -> do
      mguST points f h
      mguST points g i

    (I (IAm _ (TListF a)), I (IAm _ (TListF b))) ->
      mguST points a b

    (_, _) ->
      left (UnificationError t1 t2)

solveConstraints :: Ground l => Traversable f => f (Constraint l a) -> Either [TypeError l a] (Substitutions l a)
solveConstraints constraints =
  runST $ do
    -- Initialise mutable state.
    points <- ST.newSTRef M.empty

    -- Solve all the constraints independently.
    es <- fmap sequenceErrors . for constraints $ \c ->
      case c of
        Equal t1 t2 ->
          fmap (first D.singleton) (mostGeneralUnifierST points t1 t2)

    -- Retrieve the remaining points and produce a substitution map
    solvedPoints <- ST.readSTRef points
    for (first D.toList es) $ \_ -> do
      fmap Substitutions (for solvedPoints (UF.descriptor <=< UF.repr))

union :: STRef s (Map Int (UF.Point s (IType l a))) -> IType l a -> IType l a -> ST s ()
union points t1 t2 = do
  p1 <- getPoint points t1
  p2 <- getPoint points t2
  UF.union p1 p2

-- | Fills the 'lookup' API hole in the union-find package.
getPoint :: STRef s (Map Int (UF.Point s (IType l a))) -> IType l a -> ST s (UF.Point s (IType l a))
getPoint mref ty =
  case ty of
    I (IDunno _ x) -> do
      ps <- ST.readSTRef mref
      case M.lookup x ps of
        Just point ->
          pure point
        Nothing -> do
          point <- UF.fresh ty
          ST.modifySTRef' mref (M.insert x point)
          pure point

    I (IAm _ _) ->
      UF.fresh ty
{-# INLINE getPoint #-}

getRepr :: STRef s (Map Int (UF.Point s (IType l a))) -> Int -> ST s (Maybe (IType l a))
getRepr points x = do
  ps <- ST.readSTRef points
  for (M.lookup x ps) (UF.descriptor <=< UF.repr)

hoistErrors :: Either e a -> Errors e a
hoistErrors e =
  case e of
    Left es ->
      Other (Constant es)

    Right a ->
      Pure a

-- | Like 'sequence', but accumulating all errors in case of a 'Left'.
sequenceErrors :: (Monoid e, Traversable f) => f (Either e a) -> Either e (f a)
sequenceErrors =
  runErrors . traverse hoistErrors
