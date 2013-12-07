module Purecoin.Core.BlockChain
       ( BlockChain, newChain, getCoinMap
       , AddBlockResult, AddBlockMonad(..), addBlock)
       where

import Control.Applicative ((<$>))
import Control.Arrow ((***), (&&&))
import Data.List (unfoldr, sort)
import Data.Maybe (listToMaybe)
import Data.Monoid (mempty, mconcat)
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Word (Word32)
import Control.Monad.State as SM
import qualified Purecoin.PSQueue as PSQ
import Data.NEList (NEList(..), toList)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Purecoin.Core.Hash (Hash, hash0)
import Purecoin.Core.Script (opPushData, opsScript, OP(OP_CHECKSIG))
import Purecoin.Core.DataTypes ( Difficulty, target, fromTarget
                               , lockView, LockView(..)
                               , BTC(..)
                               , txCoinBase, txcbLock, txcbFinal
                               , txLock, txIn, txiSequence
                               , txOutput
                               , Block, block, bPrevBlock, bBits, bTimestamp, bCoinBase, bTxs, bHash)
import Purecoin.Core.Transaction (Coins, CoinMap, emptyCoinMap, addTransaction, addCoins, prepcbTransaction)

data BlockInfo = BlockInfo {biWork      :: Integer
                           ,biNumber    :: Integer
                           ,biTimestamp :: UTCTime
                           ,biPrevBlock :: Hash
                           ,biCoinMap   :: CoinMap
                           ,biBits      :: Difficulty
                           ,biCoinBase  :: Coins
                           }

instance Eq BlockInfo where -- this is the order used for the PSQ; do not use.
  x == y = compare x y == EQ

instance Ord BlockInfo where -- this is the order used for the PSQ; do not use.
  compare x y = compare (biWork y) (biWork x) -- comparision reversed because PSQ uses min priority

data BlockChain a = BlockChain { bcChain :: PSQ.PSQ Hash BlockInfo -- Must be non-empty.
                               , maxTarget :: Difficulty -- make this a typeclass method
                               }
chain :: BlockChain a -> Hash -> [BlockInfo]
chain bc = unfoldr go
 where
   go h = do bi <- PSQ.lookup h . bcChain $ bc
             return (bi, (biPrevBlock bi))

coinValue :: Integer -> BTC
coinValue n = Ƀ (50 / (2 ^ (n `div` 210000)))

work :: Difficulty -> Integer
work x = sha256size `div` (target x + 1)
 where
  sha256size = 2^256

newChain :: Word32 -> UTCTime -> Difficulty -> Word32 -> Maybe (BlockChain a)
newChain version time difficulty nonce =
  do txo <- txOutput (coinValue genesisNumber) (opsScript [opPushData $ BS.pack [0x04,0x67,0x8a,0xfd,0xb0,0xfe,0x55,0x48,0x27,0x19,0x67,0xf1,0xa6,0x71,0x30,0xb7,0x10,0x5c,0xd6,0xa8,0x28,0xe0,0x39,0x09,0xa6,0x79,0x62,0xe0,0xea,0x1f,0x61,0xde,0xb6,0x49,0xf6,0xbc,0x3f,0x4c,0xef,0x38,0xc4,0xf3,0x55,0x04,0xe5,0x1e,0xc1,0x12,0xde,0x5c,0x38,0x4d,0xf7,0xba,0x0b,0x8d,0x57,0x8a,0x4c,0x70,0x2b,0x6b,0xf1,0x1d,0x5f],OP_CHECKSIG])
     genesis <- block version hash0 time difficulty nonce (txCoinBase 1 (opsScript [opPushData $ BS.pack [0xff,0xff,0,0x1d],opPushData $ BS.pack [0x04],opPushData theTimes]) (NENil txo)) []
     genesisCoins <- either fail return $ prepcbTransaction (coinValue genesisNumber, mempty) (bCoinBase genesis)
     let genesisInfo = BlockInfo {biWork      = work (bBits genesis)
                                 ,biNumber    = genesisNumber
                                 ,biPrevBlock = hash0
                                 ,biTimestamp = bTimestamp genesis
                                 ,biBits      = bBits genesis
                                 ,biCoinMap   = emptyCoinMap
                                 ,biCoinBase  = genesisCoins
                                 }
     -- TODO: I had a bug where I used hash instead of bHash.  I need to do something with the type system to prevent this in the future --
     return (BlockChain (PSQ.singleton (bHash genesis) genesisInfo) (bBits genesis))
 where
  genesisNumber = 0
  theTimes = BSC.pack "The Times 03/Jan/2009 Chancellor on brink of second bailout for banks"

getCoinMap :: BlockChain a -> CoinMap
getCoinMap = biCoinMap . PSQ.prio . PSQ.findMin . bcChain

data AddBlockMonad a = AddBlockResult a
                     | OrphanBlock Block
                     | AddBlockError String

type AddBlockResult a = AddBlockMonad (BlockChain a)

instance Monad AddBlockMonad where
  return = AddBlockResult
  (AddBlockResult x) >>= f = f x
  (OrphanBlock b)    >>= f = OrphanBlock b
  (AddBlockError e)  >>= f = AddBlockError e
  fail = AddBlockError

addBlock :: Block -> IO (BlockChain a -> AddBlockResult a)
addBlock bl = do ct <- getCurrentTime
                 return $ updateBlockChain ct
 where
  prevHash = bPrevBlock bl
  newCoinBase = bCoinBase bl
  newTxs = bTxs bl
  newBits = bBits bl
  newTimestamp = bTimestamp bl
  updateBlockChain currentTime bc = do newBlockInfo <- go (chain bc prevHash)
                                       return $ bc{bcChain = PSQ.insert (bHash bl) newBlockInfo (bcChain bc)}
   where
    maxBits = maxTarget bc
    go [] = OrphanBlock bl
    go theChain@(prevBlockInfo:_) = do checkTarget
                                       checkTimestamp
                                       checkFinalTxs
                                       (cbase, newMap) <- either fail return $ runStateT processTxs (biCoinMap prevBlockInfo)
                                       return $ BlockInfo {biWork      = (biWork prevBlockInfo) + work (bBits bl)
                                                          ,biNumber    = newNumber
                                                          ,biPrevBlock = prevHash
                                                          ,biTimestamp = newTimestamp
                                                          ,biBits      = newBits
                                                          ,biCoinMap   = maybe newMap (\cb -> SM.execState (addCoins cb) newMap) gradcb
                                                          ,biCoinBase  = cbase
                                                          }
     where
      newNumber = succ (biNumber prevBlockInfo)
      processTxs = do fees <- mapM addTransaction newTxs
                      let totalFees = (mconcat *** mconcat) . unzip $ (coinValue newNumber, mempty):fees
                      lift (prepcbTransaction totalFees newCoinBase)
      -- on the *next* block the 98th-block-before-the-previous-block's coinbase will be useable.
      gradcb = fmap biCoinBase . listToMaybe . drop 98 $ theChain
      checkTarget = maybe (fail errTarget) return $ guard (requiredBits == newBits)
       where
        requiredBits | changeTarget = fromTarget (min newDifficulty (target maxBits))
                     | otherwise    = lastTarget
         where
          blocksPerTarget :: Int
          blocksPerTarget = 14 * 24 * 6
          tenMinutes     = 10 * 60
          lastTarget = biBits prevBlockInfo
          changeTarget = 0 == (fromIntegral (biNumber prevBlockInfo) + 1) `mod` blocksPerTarget
          -- notice the time it takes to generate a new block after a change in difficutly isn't taken into account!
          timeSpan = diffUTCTime (biTimestamp prevBlockInfo) (biTimestamp (theChain!!(blocksPerTarget-1)))
          targetTimeSpan = toInteger (blocksPerTarget * tenMinutes)
          lowerTimeSpan = targetTimeSpan `div` 4
          upperTimeSpan = targetTimeSpan * 4
          -- Try to round the same way the offical client does.
          newDifficulty :: Integer
          newDifficulty = (target lastTarget) * clamp lowerTimeSpan (round timeSpan) upperTimeSpan `div` targetTimeSpan
        errTarget = "Block "++show (bHash bl)++" should have difficulty "++show (target requiredBits)++ " but has difficulty "++show (target newBits)++" instead."
      checkTimestamp = maybe (fail (errTimestamp currentTime)) return
                     $ do pts <- prevTimestamp
                          guard (pts < newTimestamp && newTimestamp <= addUTCTime twoHours currentTime)
       where
        twoHours = 2 * 60 * 60
        prevTimestamp = median . map (biTimestamp) . take 11 $ theChain
        errTimestamp ct = "Block "++show (bHash bl)++" time of "++show newTimestamp++" is before "++show prevTimestamp++" or after currentTime "++show ct
      checkFinalTxs = maybe (fail errFinalTxs) return $ guard (all isFinalTx (cbLock:txLocks))
       where
        errFinalTxs = "Block "++show (bHash bl)++" contains non-final transactions" -- more precise error message needed.
        cbLock = (txcbLock &&& txcbFinal) newCoinBase
        txLocks = map (txLock &&& (all txiFinal . toList . txIn)) newTxs
        txiFinal txi = txiSequence txi == maxBound
        isFinalTx (lock, finalSeq) = finalSeq || check (lockView lock)
         where
          check Unlocked = True
          check (LockBlock n) = newNumber < n
          check (LockTime t) = newTimestamp < t

median :: (Ord a) => [a] -> Maybe a
median [] = Nothing
median l = Just (sl!!((length sl) `div` 2))
  where
    sl = sort l

clamp :: (Ord a) => a -> a -> a -> a
clamp low x high | x < low = low
                 | high < x = high
                 | otherwise = x
