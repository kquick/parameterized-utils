{-|
Description : Finite maps with parameterized key and value types
Copyright   : (c) Galois, Inc 2014-2019

This module defines finite maps where the key and value types are
parameterized by an arbitrary kind.

Some code was adapted from containers.
-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE Trustworthy #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeInType #-}
module Data.Parameterized.Map
  ( MapF
    -- * Construction
  , Data.Parameterized.Map.empty
  , singleton
  , insert
  , insertWith
  , delete
  , union
    -- * Query
  , null
  , lookup
  , findWithDefault
  , member
  , notMember
  , size
    -- * Conversion
  , keys
  , elems
  , fromList
  , toList
  , toAscList
  , toDescList
  , fromKeys
  , fromKeysM
   -- * Filter
  , filter
  , filterWithKey
  , filterGt
  , filterLt
    -- * Folds
  , foldlWithKey
  , foldlWithKey'
  , foldrWithKey
  , foldrWithKey'
  , foldMapWithKey
  , foldlMWithKey
  , foldrMWithKey
    -- * Traversals
  , map
  , mapWithKey
  , mapMaybe
  , mapMaybeWithKey
  , traverseWithKey
  , traverseWithKey_
  , traverseMaybeWithKey
    -- * Complex interface.
  , UpdateRequest(..)
  , Updated(..)
  , updatedValue
  , updateAtKey
  , mergeWithKeyM
  , module Data.Parameterized.Classes
    -- * Pair
  , Pair(..)
  ) where

import           Control.Applicative hiding (empty)
import           Control.Lens (Traversal', Lens')
import           Control.Monad.Identity
import           Data.Kind (Type)
import           Data.List (intercalate, foldl')
import           Data.Monoid

import           Data.Parameterized.Classes
import           Data.Parameterized.Some
import           Data.Parameterized.Pair ( Pair(..) )
import           Data.Parameterized.TraversableF
import           Data.Parameterized.Utils.BinTree
  ( MaybeS(..)
  , fromMaybeS
  , Updated(..)
  , updatedValue
  , TreeApp(..)
  , bin
  , IsBinTree(..)
  , balanceL
  , balanceR
  , glue
  )
import qualified Data.Parameterized.Utils.BinTree as Bin

#if MIN_VERSION_base(4,8,0)
import           Prelude hiding (filter, lookup, map, traverse, null)
#else
import           Prelude hiding (filter, lookup, map, null)
#endif

------------------------------------------------------------------------
-- * Pair

comparePairKeys :: OrdF k => Pair k a -> Pair k a -> Ordering
comparePairKeys (Pair x _) (Pair y _) = toOrdering (compareF x y)
{-# INLINABLE comparePairKeys #-}

------------------------------------------------------------------------
-- MapF

-- | A map from parameterized keys to values with the same parameter type.
data MapF (k :: v -> Type) (a :: v -> Type) where
  Bin :: {-# UNPACK #-}
         !Size -- Number of elements in tree.
      -> !(k x)
      -> !(a x)
      -> !(MapF k a)
      -> !(MapF k a)
      -> MapF k a
  Tip :: MapF k a

type Size = Int

-- | Return empty map
empty :: MapF k a
empty = Tip

-- | Return true if map is empty
null :: MapF k a -> Bool
null Tip = True
null Bin{} = False

-- | Return map containing a single element
singleton :: k tp -> a tp -> MapF k a
singleton k x = Bin 1 k x Tip Tip

instance Bin.IsBinTree (MapF k a) (Pair k a) where
  asBin (Bin _ k v l r) = BinTree (Pair k v) l r
  asBin Tip = TipTree

  tip = Tip
  bin (Pair k v) l r = Bin (size l + size r + 1) k v l r

  size Tip              = 0
  size (Bin sz _ _ _ _) = sz

instance (TestEquality k, EqF a) => Eq (MapF k a) where
  x == y = size x == size y && toList x == toList y

------------------------------------------------------------------------
-- * Traversals

#ifdef __GLASGOW_HASKELL__
{-# NOINLINE [1] map #-}
{-# NOINLINE [1] traverse #-}
{-# RULES
"map/map" forall (f :: (forall tp . f tp -> g tp)) (g :: (forall tp . g tp -> h tp)) xs
               . map g (map f xs) = map (g . f) xs
"map/traverse" forall (f :: (forall tp . f tp -> m (g tp))) (g :: (forall tp . g tp -> h tp)) xs
               . fmap (map g) (traverse f xs) = traverse (\v -> g <$> f v) xs
"traverse/map"
  forall (f :: (forall tp . f tp -> g tp)) (g :: (forall tp . g tp -> m (h tp))) xs
       . traverse g (map f xs) = traverse (\v -> g (f v)) xs
"traverse/traverse"
  forall (f :: (forall tp . f tp -> m (g tp))) (g :: (forall tp . g tp -> m (h tp))) xs
       . traverse f xs >>= traverse g = traverse (\v -> f v >>= g) xs
 #-}
#endif


-- | Apply function to all elements in map.
mapWithKey
  :: (forall tp . ktp tp -> f tp -> g tp)
  -> MapF ktp f
  -> MapF ktp g
mapWithKey _ Tip = Tip
mapWithKey f (Bin sx kx x l r) = Bin sx kx (f kx x) (mapWithKey f l) (mapWithKey f r)

-- | Modify elements in a map
map :: (forall tp . f tp -> g tp) -> MapF ktp f -> MapF ktp g
map f = mapWithKey (\_ x -> f x)

-- | Map keys and elements and collect `Just` results.
mapMaybeWithKey :: (forall tp . k tp -> f tp -> Maybe (g tp)) -> MapF k f -> MapF k g
mapMaybeWithKey _ Tip = Tip
mapMaybeWithKey f (Bin _ k x l r) =
  case f k x of
    Just y -> Bin.link (Pair k y) (mapMaybeWithKey f l) (mapMaybeWithKey f r)
    Nothing -> Bin.merge (mapMaybeWithKey f l) (mapMaybeWithKey f r)

-- | Map elements and collect `Just` results.
mapMaybe :: (forall tp . f tp -> Maybe (g tp)) -> MapF ktp f -> MapF ktp g
mapMaybe f = mapMaybeWithKey (\_ x -> f x)

-- | Traverse elements in a map
traverse :: Applicative m => (forall tp . f tp -> m (g tp)) -> MapF ktp f -> m (MapF ktp g)
traverse _ Tip = pure Tip
traverse f (Bin sx kx x l r) =
  (\l' x' r' -> Bin sx kx x' l' r') <$> traverse f l <*> f x <*> traverse f r

-- | Traverse elements in a map
traverseWithKey
  :: Applicative m
  => (forall tp . ktp tp -> f tp -> m (g tp))
  -> MapF ktp f
  -> m (MapF ktp g)
traverseWithKey _ Tip = pure Tip
traverseWithKey f (Bin sx kx x l r) =
   (\l' x' r' -> Bin sx kx x' l' r') <$> traverseWithKey f l <*> f kx x <*> traverseWithKey f r

-- | Traverse elements in a map without returning result.
traverseWithKey_
  :: Applicative m
  => (forall tp . ktp tp -> f tp -> m ())
  -> MapF ktp f
  -> m ()
traverseWithKey_ = \f -> foldrWithKey (\k v r -> f k v *> r) (pure ())
{-# INLINABLE traverseWithKey_ #-}

-- | Traverse keys\/values and collect the 'Just' results.
traverseMaybeWithKey :: Applicative f
                     => (forall tp . k tp -> a tp -> f (Maybe (b tp)))
                     -> MapF k a -> f (MapF k b)
traverseMaybeWithKey _ Tip = pure Tip
traverseMaybeWithKey f (Bin _ kx x Tip Tip) = maybe Tip (\x' -> Bin 1 kx x' Tip Tip) <$> f kx x
traverseMaybeWithKey f (Bin _ kx x l r) =
    liftA3 combine (traverseMaybeWithKey f l) (f kx x) (traverseMaybeWithKey f r)
  where
    combine l' mx r' = seq l' $ seq r' $
      case mx of
        Just x' -> Bin.link (Pair kx x') l' r'
        Nothing -> Bin.merge l' r'
{-# INLINABLE traverseMaybeWithKey #-}

type instance IndexF   (MapF k v) = k
type instance IxValueF (MapF k v) = v

-- | Turn a map key into a traversal that visits the indicated element in the map, if it exists.
instance forall (k:: a -> Type) v. OrdF k => IxedF a (MapF k v) where
  ixF :: k x -> Traversal' (MapF k v) (v x)
  ixF i f m = updatedValue <$> updateAtKey i (pure Nothing) (\x -> Set <$> f x) m

-- | Turn a map key into a lens that points into the indicated position in the map.
instance forall (k:: a -> Type) v. OrdF k => AtF a (MapF k v) where
  atF :: k x -> Lens' (MapF k v) (Maybe (v x))
  atF i f m = updatedValue <$> updateAtKey i (f Nothing) (\x -> maybe Delete Set <$> f (Just x)) m


-- | Lookup value in map.
lookup :: OrdF k => k tp -> MapF k a -> Maybe (a tp)
lookup k0 = seq k0 (go k0)
  where
    go :: OrdF k => k tp -> MapF k a -> Maybe (a tp)
    go _ Tip = Nothing
    go k (Bin _ kx x l r) =
      case compareF k kx of
        LTF -> go k l
        GTF -> go k r
        EQF -> Just x
{-# INLINABLE lookup #-}

-- | @findWithDefault d k m@ returns the value bound to @k@ in the map @m@, or @d@
-- if @k@ is not bound in the map.
findWithDefault :: OrdF k => a tp -> k tp -> MapF k a -> a tp
findWithDefault = \def k -> seq k (go def k)
  where
    go :: OrdF k => a tp -> k tp -> MapF k a -> a tp
    go d _ Tip = d
    go d k (Bin _ kx x l r) =
      case compareF k kx of
        LTF -> go d k l
        GTF -> go d k r
        EQF -> x
{-# INLINABLE findWithDefault #-}

-- | Return true if key is bound in map.
member :: OrdF k => k tp -> MapF k a -> Bool
member k0 = seq k0 (go k0)
  where
    go :: OrdF k => k tp -> MapF k a -> Bool
    go _ Tip = False
    go k (Bin _ kx _ l r) =
      case compareF k kx of
        LTF -> go k l
        GTF -> go k r
        EQF -> True
{-# INLINABLE member #-}

-- | Return true if key is not bound in map.
notMember :: OrdF k => k tp -> MapF k a -> Bool
notMember k m = not $ member k m
{-# INLINABLE notMember #-}

instance FunctorF (MapF ktp) where
  fmapF = map

instance FoldableF (MapF ktp) where
  foldrF f z = go z
    where go z' Tip             = z'
          go z' (Bin _ _ x l r) = go (f x (go z' r)) l

instance TraversableF (MapF ktp) where
  traverseF = traverse

instance (ShowF ktp, ShowF rtp) => Show (MapF ktp rtp) where
  show m = showMap showF showF m

-- | Return all keys of the map in ascending order.
keys :: MapF k a -> [Some k]
keys = foldrWithKey (\k _ l -> Some k : l) []

-- | Return all elements of the map in the ascending order of their keys.
elems :: MapF k a -> [Some a]
elems = foldrF (\e l -> Some e : l) []

-- | Perform a left fold with the key also provided.
foldlWithKey :: (forall s . b -> k s -> a s -> b) -> b -> MapF k a -> b
foldlWithKey _ z Tip = z
foldlWithKey f z (Bin _ kx x l r) =
  let lz = foldlWithKey f z l
      kz = f lz kx x
   in foldlWithKey f kz r

-- | Perform a strict left fold with the key also provided.
foldlWithKey' :: (forall s . b -> k s -> a s -> b) -> b -> MapF k a -> b
foldlWithKey' _ z Tip = z
foldlWithKey' f z (Bin _ kx x l r) =
  let lz = foldlWithKey f z l
      kz = seq lz $ f lz kx x
   in seq kz $ foldlWithKey f kz r

-- | Perform a right fold with the key also provided.
foldrWithKey :: (forall s . k s -> a s -> b -> b) -> b -> MapF k a -> b
foldrWithKey _ z Tip = z
foldrWithKey f z (Bin _ kx x l r) =
  foldrWithKey f (f kx x (foldrWithKey f z r)) l

-- | Perform a strict right fold with the key also provided.
foldrWithKey' :: (forall s . k s -> a s -> b -> b) -> b -> MapF k a -> b
foldrWithKey' _ z Tip = z
foldrWithKey' f z (Bin _ kx x l r) =
  let rz = foldrWithKey f z r
      kz = seq rz $ f kx x rz
   in seq kz $ foldrWithKey f kz l

-- | Fold the keys and values using the given monoid.
foldMapWithKey :: Monoid m => (forall s . k s -> a s -> m) -> MapF k a -> m
foldMapWithKey _ Tip = mempty
foldMapWithKey f (Bin _ kx x l r) = foldMapWithKey f l <> f kx x <> foldMapWithKey f r

-- | A monadic left-to-right fold over keys and values in the map.
foldlMWithKey :: Monad m => (forall s . b -> k s -> a s -> m b) -> b -> MapF k a -> m b
foldlMWithKey f z0 m = foldrWithKey (\k a r z ->  f z k a >>= r) pure m z0

-- | A monadic right-to-left fold over keys and values in the map.
foldrMWithKey :: Monad m => (forall s . k s -> a s -> b -> m b) -> b -> MapF k a -> m b
foldrMWithKey f z0 m = foldlWithKey (\r k a z ->  f k a z >>= r) pure m z0

-- | Pretty print keys and values in map.
showMap :: (forall tp . ktp tp -> String)
        -> (forall tp . rtp tp -> String)
        -> MapF ktp rtp
        -> String
showMap ppk ppv m = "{ " ++ intercalate ", " l ++ " }"
  where l = foldrWithKey (\k a l0 -> (ppk k ++ " -> " ++ ppv a) : l0) [] m

------------------------------------------------------------------------
-- filter

-- | Return entries with values that satisfy a predicate.
filter :: (forall tp . f tp -> Bool) -> MapF k f -> MapF k f
filter f = filterWithKey (\_ v -> f v)

-- | Return key-value pairs that satisfy a predicate.
filterWithKey :: (forall tp . k tp -> f tp -> Bool) -> MapF k f -> MapF k f
filterWithKey _ Tip = Tip
filterWithKey f (Bin _ k x l r)
  | f k x     = Bin.link (Pair k x) (filterWithKey f l) (filterWithKey f r)
  | otherwise = Bin.merge (filterWithKey f l) (filterWithKey f r)

compareKeyPair :: OrdF k => k tp -> Pair k a -> Ordering
compareKeyPair k = \(Pair x _) -> toOrdering (compareF k x)

-- | @filterGt k m@ returns submap of @m@ that only contains entries
-- that are larger than @k@.
filterGt :: OrdF k => k tp -> MapF k v -> MapF k v
filterGt k m = fromMaybeS m (Bin.filterGt (compareKeyPair k) m)
{-# INLINABLE filterGt #-}

-- | @filterLt k m@ returns submap of @m@ that only contains entries
-- that are smaller than @k@.
filterLt :: OrdF k => k tp -> MapF k v -> MapF k v
filterLt k m = fromMaybeS m (Bin.filterLt (compareKeyPair k) m)
{-# INLINABLE filterLt #-}

------------------------------------------------------------------------
-- User operations

-- | Insert a binding into the map, replacing the existing binding if needed.
insert :: OrdF k => k tp -> a tp -> MapF k a -> MapF k a
insert = \k v m -> seq k $ updatedValue (Bin.insert comparePairKeys (Pair k v) m)
{-# INLINABLE insert #-}
-- {-# SPECIALIZE Bin.insert :: OrdF k => Pair k a -> MapF k a -> Updated (MapF k a) #-}

-- | Insert a binding into the map, replacing the existing binding if needed.
insertWithImpl :: OrdF k => (a tp -> a tp -> a tp) -> k tp -> a tp -> MapF k a -> Updated (MapF k a)
insertWithImpl f k v t = seq k $
  case t of
    Tip -> Bin.Updated (Bin 1 k v Tip Tip)
    Bin sz yk yv l r ->
      case compareF k yk of
        LTF ->
          case insertWithImpl f k v l of
            Bin.Updated l'   -> Bin.Updated   (Bin.balanceL (Pair yk yv) l' r)
            Bin.Unchanged l' -> Bin.Unchanged (Bin sz yk yv l' r)
        GTF ->
          case insertWithImpl f k v r of
            Bin.Updated r'   -> Bin.Updated   (Bin.balanceR (Pair yk yv) l r')
            Bin.Unchanged r' -> Bin.Unchanged (Bin sz yk yv l r')
        EQF -> Bin.Unchanged (Bin sz yk (f v yv) l r)
{-# INLINABLE insertWithImpl #-}

-- | @insertWith f new m@ inserts the binding into @m@.
--
-- It inserts @f new old@ if @m@ already contains an equivalent value
-- @old@, and @new@ otherwise.  It returns an 'Unchanged' value if the
-- map stays the same size and an 'Updated' value if a new entry was
-- inserted.
insertWith :: OrdF k => (a tp -> a tp -> a tp) -> k tp -> a tp -> MapF k a -> MapF k a
insertWith = \f k v t -> seq k $ updatedValue (insertWithImpl f k v t)
{-# INLINABLE insertWith #-}

-- | Delete a value from the map if present.
delete :: OrdF k => k tp -> MapF k a -> MapF k a
delete = \k m -> seq k $ fromMaybeS m $ Bin.delete (p k) m
  where p :: OrdF k => k tp -> Pair k a -> Ordering
        p k (Pair kx _) = toOrdering (compareF k kx)
{-# INLINABLE delete #-}
{-# SPECIALIZE Bin.delete :: (Pair k a -> Ordering) -> MapF k a -> MaybeS (MapF k a) #-}

-- | Left-biased union of two maps. The resulting map will
-- contain the union of the keys of the two arguments. When
-- a key is contained in both maps the value from the first
-- map will be preserved.
union :: OrdF k => MapF k a -> MapF k a -> MapF k a
union t1 t2 = Bin.union comparePairKeys t1 t2
{-# INLINABLE union #-}
-- {-# SPECIALIZE Bin.union compare :: OrdF k => MapF k a -> MapF k a -> MapF k a #-}

------------------------------------------------------------------------
-- updateAtKey

-- | 'UpdateRequest' tells what to do with a found value
data UpdateRequest v
   = -- | Keep the current value.
     Keep
     -- | Set the value to a new value.
   | Set !v
     -- | Delete a value.
   | Delete

data AtKeyResult k a where
  AtKeyUnchanged :: AtKeyResult k a
  AtKeyInserted :: MapF k a -> AtKeyResult k a
  AtKeyModified :: MapF k a -> AtKeyResult k a
  AtKeyDeleted  :: MapF k a -> AtKeyResult k a

atKey' :: (OrdF k, Functor f)
       => k tp
       -> f (Maybe (a tp)) -- ^ Function to call if no element is found.
       -> (a tp -> f (UpdateRequest (a tp)))
       -> MapF k a
       -> f (AtKeyResult k a)
atKey' k onNotFound onFound t =
  case asBin t of
    TipTree -> ins <$> onNotFound
      where ins Nothing  = AtKeyUnchanged
            ins (Just v) = AtKeyInserted (singleton k v)
    BinTree yp@(Pair kx y) l r ->
      case compareF k kx of
        LTF -> ins <$> atKey' k onNotFound onFound l
          where ins AtKeyUnchanged = AtKeyUnchanged
                ins (AtKeyInserted l') = AtKeyInserted (balanceL yp l' r)
                ins (AtKeyModified l') = AtKeyModified (bin      yp l' r)
                ins (AtKeyDeleted  l') = AtKeyDeleted  (balanceR yp l' r)
        GTF -> ins <$> atKey' k onNotFound onFound r
          where ins AtKeyUnchanged = AtKeyUnchanged
                ins (AtKeyInserted r') = AtKeyInserted (balanceR yp l r')
                ins (AtKeyModified r') = AtKeyModified (bin      yp l r')
                ins (AtKeyDeleted  r') = AtKeyDeleted  (balanceL yp l r')
        EQF -> ins <$> onFound y
          where ins Keep    = AtKeyUnchanged
                ins (Set x) = AtKeyModified (bin (Pair kx x) l r)
                ins Delete  = AtKeyDeleted (glue l r)
{-# INLINABLE atKey' #-}

-- | Log-time algorithm that allows a value at a specific key to be added, replaced,
-- or deleted.
updateAtKey :: (OrdF k, Functor f)
            => k tp -- ^ Key to update
            -> f (Maybe (a tp))
               -- ^ Action to call if nothing is found
            -> (a tp -> f (UpdateRequest (a tp)))
               -- ^ Action to call if value is found.
            -> MapF k a
               -- ^ Map to update
            -> f (Updated (MapF k a))
updateAtKey k onNotFound onFound t = ins <$> atKey' k onNotFound onFound t
  where ins AtKeyUnchanged = Unchanged t
        ins (AtKeyInserted t') = Updated t'
        ins (AtKeyModified t') = Updated t'
        ins (AtKeyDeleted  t') = Updated t'
{-# INLINABLE updateAtKey #-}

-- | Create a Map from a list of pairs.
fromList :: OrdF k => [Pair k a] -> MapF k a
fromList = foldl' (\m (Pair k a) -> insert k a m) Data.Parameterized.Map.empty

-- | Return list of key-values pairs in map in ascending order.
toAscList :: MapF k a -> [Pair k a]
toAscList = foldrWithKey (\k x l -> Pair k x : l) []

-- | Return list of key-values pairs in map in descending order.
toDescList :: MapF k a -> [Pair k a]
toDescList = foldlWithKey (\l k x -> Pair k x : l) []

-- | Return list of key-values pairs in map.
toList :: MapF k a -> [Pair k a]
toList = toAscList

-- | Generate a map from a foldable collection of keys and a
-- function from keys to values.
fromKeys :: forall m (t :: Type -> Type) (a :: k -> Type) (v :: k -> Type)
          .  (Monad m, Foldable t, OrdF a)
            => (forall tp . a tp -> m (v tp))
            -- ^ Function for evaluating a register value.
            -> t (Some a)
               -- ^ Set of X86 registers
            -> m (MapF a v)
fromKeys f = foldM go empty
  where go :: MapF a v -> Some a -> m (MapF a v)
        go m (Some k) = (\v -> insert k v m) <$> f k

-- | Generate a map from a foldable collection of keys and a monadic
-- function from keys to values.
fromKeysM :: forall m (t :: Type -> Type) (a :: k -> Type) (v :: k -> Type)
          .  (Monad m, Foldable t, OrdF a)
           => (forall tp . a tp -> m (v tp))
           -- ^ Function for evaluating an input value to store the result in the map.
           -> t (Some a)
           -- ^ Set of input values (traversed via folding)
           -> m (MapF a v)
fromKeysM f = foldM go empty
  where go :: MapF a v -> Some a -> m (MapF a v)
        go m (Some k) = (\v -> insert k v m) <$> f k

filterGtMaybe :: OrdF k => MaybeS (k x) -> MapF k a -> MapF k a
filterGtMaybe NothingS m = m
filterGtMaybe (JustS k) m = filterGt k m

filterLtMaybe :: OrdF k => MaybeS (k x) -> MapF k a -> MapF k a
filterLtMaybe NothingS m = m
filterLtMaybe (JustS k) m = filterLt k m

-- | Merge bindings in two maps to get a third.
--
-- The first function is used to merge elements that occur under the
-- same key in both maps. Return Just to add an entry into the
-- resulting map under this key or Nothing to remove this key from the
-- resulting map.
--
-- The second function will be applied to submaps of the first map argument
-- where no keys overlap with the second map argument. The result of this
-- function must be a map with a subset of the keys of its argument.
-- This means the function can alter the values of its argument and it can
-- remove key-value pairs from it, but it must not introduce new keys.
--
-- Third function is analogous to the second function except that it applies
-- to the second map argument of 'mergeWithKeyM' instead of the first.
--
-- Common examples of the two functions include 'id' when constructing a union
-- or 'const' 'empty' when constructing an intersection.
mergeWithKeyM :: forall k a b c m
               . (Applicative m, OrdF k)
              => (forall tp . k tp -> a tp -> b tp -> m (Maybe (c tp)))
              -> (MapF k a -> m (MapF k c))
              -> (MapF k b -> m (MapF k c))
              -> MapF k a
              -> MapF k b
              -> m (MapF k c)
mergeWithKeyM f g1 g2 = go
  where
    go Tip t2 = g2 t2
    go t1 Tip = g1 t1
    go t1 t2 = hedgeMerge NothingS NothingS t1 t2

    hedgeMerge :: MaybeS (k x) -> MaybeS (k y) -> MapF k a -> MapF k b -> m (MapF k c)
    hedgeMerge _   _   t1  Tip = g1 t1
    hedgeMerge blo bhi Tip (Bin _ kx x l r) =
      g2 $ Bin.link (Pair kx x) (filterGtMaybe blo l) (filterLtMaybe bhi r)
    hedgeMerge blo bhi (Bin _ kx x l r) t2 =
        let Bin.PairS found trim_t2 = trimLookupLo kx bhi t2
            resolve_g1 :: MapF k c -> MapF k c -> MapF k c -> MapF k c
            resolve_g1 Tip = Bin.merge
            resolve_g1 (Bin _ k' x' Tip Tip) = Bin.link (Pair k' x')
            resolve_g1 _ = error "mergeWithKey: Bad function g1"
            resolve_f Nothing = Bin.merge
            resolve_f (Just x') = Bin.link (Pair kx x')
         in case found of
              Nothing ->
                resolve_g1 <$> g1 (singleton kx x)
                           <*> hedgeMerge blo bmi l (trim blo bmi t2)
                           <*> hedgeMerge bmi bhi r trim_t2
              Just x2 ->
                resolve_f <$> f kx x x2
                          <*> hedgeMerge blo bmi l (trim blo bmi t2)
                          <*> hedgeMerge bmi bhi r trim_t2
      where bmi = JustS kx
{-# INLINABLE mergeWithKeyM #-}

{--------------------------------------------------------------------
  [trim blo bhi t] trims away all subtrees that surely contain no
  values between the range [blo] to [bhi]. The returned tree is either
  empty or the key of the root is between @blo@ and @bhi@.
--------------------------------------------------------------------}
trim :: OrdF k => MaybeS (k x) -> MaybeS (k y) -> MapF k a -> MapF k a
trim NothingS   NothingS   t = t
trim (JustS lk) NothingS   t = filterGt lk t
trim NothingS   (JustS hk) t = filterLt hk t
trim (JustS lk) (JustS hk) t = filterMiddle lk hk t

-- | Returns only entries that are strictly between the two keys.
filterMiddle :: OrdF k => k x -> k y -> MapF k a -> MapF k a
filterMiddle lo hi (Bin _ k _ _ r)
  | k `leqF` lo = filterMiddle lo hi r
filterMiddle lo hi (Bin _ k _ l _)
  | k `geqF` hi = filterMiddle lo hi l
filterMiddle _  _  t = t
{-# INLINABLE filterMiddle #-}



-- Helper function for 'mergeWithKeyM'. The @'trimLookupLo' lk hk t@ performs both
-- @'trim' (JustS lk) hk t@ and @'lookup' lk t@.

-- See Note: Type of local 'go' function
trimLookupLo :: OrdF k => k tp -> MaybeS (k y) -> MapF k a -> Bin.PairS (Maybe (a tp)) (MapF k a)
trimLookupLo lk NothingS t = greater lk t
  where greater :: OrdF k => k tp -> MapF k a -> Bin.PairS (Maybe (a tp)) (MapF k a)
        greater lo t'@(Bin _ kx x l r) =
           case compareF lo kx of
             LTF -> Bin.PairS (lookup lo l) t'
             EQF -> Bin.PairS (Just x) r
             GTF -> greater lo r
        greater _ Tip = Bin.PairS Nothing Tip
trimLookupLo lk (JustS hk) t = middle lk hk t
  where middle :: OrdF k => k tp -> k y -> MapF k a -> Bin.PairS (Maybe (a tp)) (MapF k a)
        middle lo hi t'@(Bin _ kx x l r) =
          case compareF lo kx of
            LTF | kx `ltF` hi -> Bin.PairS (lookup lo l) t'
                | otherwise -> middle lo hi l
            EQF -> Bin.PairS (Just x) (lesser hi r)
            GTF -> middle lo hi r
        middle _ _ Tip = Bin.PairS Nothing Tip

        lesser :: OrdF k => k y -> MapF k a -> MapF k a
        lesser hi (Bin _ k _ l _) | k `geqF` hi = lesser hi l
        lesser _ t' = t'
