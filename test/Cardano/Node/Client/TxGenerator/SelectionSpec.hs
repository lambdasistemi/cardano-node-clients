{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.SelectionSpec
Description : Unit tests for transact-arm source picking
License     : Apache-2.0

Pins the determinism + retry contract of
'Cardano.Node.Client.TxGenerator.Selection.pickSourceIndex':

* Same @(seed, state)@ → same sequence of indices and
  same outcome (FR-002 / SC-002).
* Empty population → immediate 'Nothing' without invoking
  the predicate.
* All-rejecting predicate exhausts the retry budget and
  returns 'Nothing'.
* First-true predicate returns the first drawn index.
* RNG advancement is monotonic: calling 'pickSourceIndex'
  twice with the returned state never returns the same
  draw twice for an "always-true" predicate.
-}
module Cardano.Node.Client.TxGenerator.SelectionSpec (spec) where

import Cardano.Node.Client.TxGenerator.Selection (
    pickSourceIndex,
 )
import Control.Monad (when)
import Data.IORef (
    modifyIORef',
    newIORef,
    readIORef,
    writeIORef,
 )
import Data.Set qualified as Set
import Data.Word (Word32, Word64)
import System.Random (mkStdGen)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "TxGenerator.Selection" $ do
    describe "pickSourceIndex" $ do
        it
            "returns Nothing on empty population without \
            \calling the predicate"
            $ do
                calls <- newIORef (0 :: Int)
                let viable _ = modifyIORef' calls (+ 1) >> pure True
                result <-
                    pickSourceIndex viable 0 10 (mkStdGen 1)
                result `shouldSatisfy` isNothing'
                n <- readIORef calls
                n `shouldBe` 0

        it "returns Just on always-true predicate (first try)" $ do
            calls <- newIORef (0 :: Int)
            let viable _ = modifyIORef' calls (+ 1) >> pure True
            result <-
                pickSourceIndex viable 64 10 (mkStdGen 42)
            case result of
                Just (i, _) -> do
                    i `shouldSatisfy` (< 64)
                    readIORef calls >>= (`shouldBe` 1)
                Nothing ->
                    error "expected Just from always-true predicate"

        it "returns Nothing after maxRetries on always-false predicate" $ do
            calls <- newIORef (0 :: Int)
            let viable _ = modifyIORef' calls (+ 1) >> pure False
                maxRetries = 5 :: Word32
            result <-
                pickSourceIndex viable 64 maxRetries (mkStdGen 42)
            result `shouldSatisfy` isNothing'
            -- maxRetries + 1 attempts before giving up
            -- (the implementation makes one initial draw
            -- then up-to-maxRetries retries; so total = 6).
            n <- readIORef calls
            n `shouldBe` (fromIntegral maxRetries + 1)

        it "is deterministic: same (seed, state) → same index" $ do
            let viable _ = pure True
            r1 <- pickSourceIndex viable 64 10 (mkStdGen 12345)
            r2 <- pickSourceIndex viable 64 10 (mkStdGen 12345)
            indexOf r1 `shouldBe` indexOf r2

        it "different seeds produce different first picks (statistical)" $ do
            let viable _ = pure True
            picks <-
                mapM
                    ( \seed -> do
                        r <-
                            pickSourceIndex
                                viable
                                64
                                0
                                (mkStdGen seed)
                        pure (indexOf r)
                    )
                    [1 .. 32 :: Int]
            -- Across 32 distinct seeds we expect at least
            -- 16 distinct indices (a hard collision
            -- across all 32 would indicate a broken RNG).
            Set.size (Set.fromList picks) `shouldSatisfy` (>= 16)

        it
            "advances the RNG: re-using the returned state \
            \does not re-pick the same index for an always-\
            \true predicate"
            $ do
                let viable _ = pure True
                Just (i1, gen') <-
                    pickSourceIndex viable 1024 10 (mkStdGen 7)
                Just (i2, _) <-
                    pickSourceIndex viable 1024 10 gen'
                -- Single trial: equality is allowed by chance
                -- (1/1024 probability) but we lift the
                -- population to 1024 so the false-positive
                -- rate is vanishing.
                i1 `shouldNotBe'` i2

        it "the index returned is always within [0, population)" $ do
            let viable _ = pure True
            picks <-
                mapM
                    ( \seed -> do
                        r <-
                            pickSourceIndex
                                viable
                                17
                                0
                                (mkStdGen seed)
                        pure (indexOf r)
                    )
                    [1 .. 100 :: Int]
            let inRange = \case
                    Just i -> i < (17 :: Word64)
                    Nothing -> False
            all inRange picks `shouldBe` True

        it
            "retry consumes RNG (subsequent picks differ \
            \from a no-retry baseline)"
            $ do
                -- Reject indices 0..3 only on the first
                -- predicate call, then accept everything.
                calls <- newIORef (0 :: Int)
                let viableRetry _ = do
                        n <- readIORef calls
                        writeIORef calls (n + 1)
                        pure (n >= 1)
                Just (iWithRetry, _) <-
                    pickSourceIndex
                        viableRetry
                        1024
                        10
                        (mkStdGen 99)
                -- Now the no-retry baseline (always accept).
                Just (iNoRetry, _) <-
                    pickSourceIndex
                        (const (pure True))
                        1024
                        10
                        (mkStdGen 99)
                -- Same seed; the retry consumed one draw, so
                -- the indices must differ.
                iWithRetry `shouldNotBe'` iNoRetry

isNothing' :: Maybe a -> Bool
isNothing' Nothing = True
isNothing' _ = False

indexOf :: Maybe (Word64, a) -> Maybe Word64
indexOf = fmap fst

-- | Local 'shouldNotBe' for clarity.
shouldNotBe' :: (Eq a, Show a) => a -> a -> IO ()
shouldNotBe' x y =
    when (x == y) $
        error
            ( "expected unequal: "
                <> show x
                <> " == "
                <> show y
            )
