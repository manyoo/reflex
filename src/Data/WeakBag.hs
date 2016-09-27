-- | This module defines the 'WeakBag' type, which represents a mutable
-- collection of items that does not cause the items to be retained in memory.
-- This is useful for situations where a value needs to be inspected or modified
-- if it is still alive, but can be ignored if it is dead.
module Data.WeakBag
       ( WeakBag
       , WeakBagTicket
       , empty
       , singleton
       , insert
       , traverse
       , remove
       ) where

import Control.Concurrent.STM
import Control.Exception
import Control.Monad hiding (forM_, mapM_)
import Control.Monad.IO.Class
import Data.Foldable (forM_, mapM_)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.IORef
import System.Mem.Weak

import Prelude hiding (mapM_, traverse)

-- | A @WeakBag a@ holds a set of values of type @a@, but does not retain them -
-- that is, they can still be garbage-collected.  As long as the @a@s remain
-- alive, the 'WeakBag' will continue to refer to them.
data WeakBag a = WeakBag
  { _weakBag_nextId :: {-# UNPACK #-} !(TVar Int) --TODO: what if this wraps around?
  , _weakBag_children :: {-# UNPACK #-} !(TVar (IntMap (Weak a)))
  }

-- | When inserting an item into a 'WeakBag', a 'WeakBagTicket' is returned.  If
-- the caller retains the ticket, the item is guranteed to stay in memory (and
-- thus in the 'WeakBag').  The ticket can also be used to remove the item from
-- the 'WeakBag' prematurely (i.e. while it is still alive), using 'remove'.
data WeakBagTicket a = WeakBagTicket
  { _weakBagTicket_weakItem :: {-# UNPACK #-} !(Weak a)
  , _weakBagTicket_item :: {-# NOUNPACK #-} !a
  }

-- | Insert an item into a 'WeakBag'.
{-# INLINE insert #-}
insert :: a -- ^ The item
       -> WeakBag a -- ^ The 'WeakBag' to insert into
       -> IORef (Weak b) -- ^ An arbitrary value to be used in the following
                         -- callback
       -> (b -> IO ()) -- ^ A callback to be invoked when the item is removed
                       -- (whether automatically by the item being garbage
                       -- collected or manually via 'remove')
       -> IO (WeakBagTicket a) -- ^ Returns a 'WeakBagTicket' that ensures the
                               -- item is retained and allows the item to be
                               -- removed.
insert a (WeakBag nextId children) wbRef finalizer = {-# SCC "insert" #-} do
  a' <- evaluate a
  wbRef' <- evaluate wbRef
  myId <- atomically $ do
    myId <- readTVar nextId
    writeTVar nextId $! succ myId
    return myId
  let cleanup = do
        wb <- readIORef wbRef'
        mb <- deRefWeak wb
        forM_ mb $ \b -> do
          isLastNode <- atomically $ do --TODO: Should this run even when mb is Nothing?
            cs <- readTVar children
            let csWithoutMe = IntMap.delete myId cs
            writeTVar children $! csWithoutMe
            return $ IntMap.size csWithoutMe == 0
          when isLastNode $ finalizer b
          return ()
        return ()
  wa <- mkWeakPtr a' $ Just cleanup
  atomically $ modifyTVar' children $ IntMap.insert myId wa
  return $ WeakBagTicket
    { _weakBagTicket_weakItem = wa
    , _weakBagTicket_item = a'
    }

-- | Create an empty 'WeakBag'.
{-# INLINE empty #-}
empty :: IO (WeakBag a)
empty = {-# SCC "empty" #-} do
  nextId <- newTVarIO 1
  children <- newTVarIO IntMap.empty
  let bag = WeakBag
        { _weakBag_nextId = nextId
        , _weakBag_children = children
        }
  return bag

-- | Create a 'WeakBag' with one item; equivalent to creating the 'WeakBag' with
-- 'empty', then using 'insert'.
{-# INLINE singleton #-}
singleton :: a -> IORef (Weak b) -> (b -> IO ()) -> IO (WeakBag a, WeakBagTicket a)
singleton a wbRef finalizer = {-# SCC "singleton" #-} do
  bag <- empty
  ticket <- insert a bag wbRef finalizer
  return (bag, ticket)

{-# INLINE traverse #-}
-- | Visit every node in the given list.  If new nodes are appended during the
-- traversal, they will not be visited.  Every live node that was in the list
-- when the traversal began will be visited exactly once; however, no guarantee
-- is made about the order of the traversal.
traverse :: MonadIO m => WeakBag a -> (a -> m ()) -> m ()
traverse (WeakBag _ children) f = {-# SCC "traverse" #-} do
  cs <- liftIO $ readTVarIO children
  forM_ cs $ \c -> do
    ma <- liftIO $ deRefWeak c
    mapM_ f ma

-- | Remove an item from the 'WeakBag'; does nothing if invoked multiple times
-- on the same 'WeakBagTicket'.
{-# INLINE remove #-}
remove :: WeakBagTicket a -> IO ()
remove = {-# SCC "remove" #-} finalize . _weakBagTicket_weakItem
--TODO: Should 'remove' also drop the reference to the item?
