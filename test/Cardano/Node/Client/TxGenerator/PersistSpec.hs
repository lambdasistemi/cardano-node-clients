{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.PersistSpec
Description : Unit tests for the tx-generator's on-disk state
License     : Apache-2.0

Covers:

* Cold start: 'readNextHDIndex' returns 0 when the file is
  absent.
* Round-trip: 'writeNextHDIndex' / 'readNextHDIndex' agree.
* Atomicity under concurrent reads: while a writer is
  hammering 'writeNextHDIndex', many readers always
  observe a valid 'Word64' — never a partial line.
* Master seed: created once, then idempotent; the second
  load returns byte-for-byte the first one and is exactly
  32 bytes.
* No stale @.tmp@ files left in the state dir after a
  successful write.
-}
module Cardano.Node.Client.TxGenerator.PersistSpec (spec) where

import Cardano.Node.Client.TxGenerator.Persist (
    loadOrCreateSeed,
    masterSeedPath,
    nextHDIndexPath,
    readNextHDIndex,
    writeNextHDIndex,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (forConcurrently_, replicateConcurrently)
import Control.Monad (forM_, void)
import Data.ByteString qualified as BS
import Data.IORef (
    atomicModifyIORef',
    newIORef,
    readIORef,
 )
import Data.Word (Word64)
import System.Directory (
    doesFileExist,
    listDirectory,
 )
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldNotBe,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "TxGenerator.Persist" $ do
    describe "next-hd-index" $ do
        it "returns 0 on cold start (file absent)" $
            withSystemTempDirectory "txgen-state" $ \dir -> do
                n <- readNextHDIndex (nextHDIndexPath dir)
                n `shouldBe` 0

        it "round-trips a written value" $
            withSystemTempDirectory "txgen-state" $ \dir -> do
                let path = nextHDIndexPath dir
                forM_ ([0, 1, 17, maxBound] :: [Word64]) $ \v -> do
                    writeNextHDIndex path v
                    readBack <- readNextHDIndex path
                    readBack `shouldBe` v

        it "leaves no .tmp file behind after a successful write" $
            withSystemTempDirectory "txgen-state" $ \dir -> do
                writeNextHDIndex (nextHDIndexPath dir) 42
                files <- listDirectory dir
                filter
                    (\f -> ".tmp" `BS.isSuffixOf` packBS f)
                    files
                    `shouldBe` []

        it
            "concurrent readers always see a valid Word64 \
            \during writes"
            $ withSystemTempDirectory "txgen-state"
            $ \dir -> do
                let path = nextHDIndexPath dir
                writeNextHDIndex path 0
                stopRef <- newIORef False

                let writer = do
                        let go !i = do
                                stop <- readIORef stopRef
                                if stop
                                    then pure ()
                                    else do
                                        writeNextHDIndex path i
                                        go (i + 1)
                        go 1

                let reader = do
                        let go = do
                                stop <- readIORef stopRef
                                if stop
                                    then pure ()
                                    else do
                                        _ <- readNextHDIndex path
                                        go
                        go

                -- 1 writer + 8 readers for 200 ms; if any reader
                -- ever sees a malformed file, readNextHDIndex
                -- throws via 'fail'.
                _ <-
                    replicateConcurrently 1 writer
                        `raceWith` ( do
                                        replicateConcurrently 8 reader
                                            `raceWith` ( do
                                                            threadDelay 200_000
                                                            atomicModifyIORef'
                                                                stopRef
                                                                (const (True, ()))
                                                       )
                                   )
                pure ()

    describe "master.seed" $ do
        it
            "creates a 32-byte seed on first load and \
            \returns it idempotently"
            $ withSystemTempDirectory "txgen-state"
            $ \dir -> do
                let path = masterSeedPath dir
                seed1 <- loadOrCreateSeed path
                BS.length seed1 `shouldBe` 32
                seed2 <- loadOrCreateSeed path
                seed2 `shouldBe` seed1

        it "writes a non-zero seed (not all-zeroes by accident)" $
            withSystemTempDirectory "txgen-state" $ \dir -> do
                seed <- loadOrCreateSeed (masterSeedPath dir)
                seed `shouldNotBe` BS.replicate 32 0

        it "the seed file exists after creation" $
            withSystemTempDirectory "txgen-state" $ \dir -> do
                let path = masterSeedPath dir
                _ <- loadOrCreateSeed path
                doesFileExist path
                    >>= (`shouldSatisfy` id)

{- | Run two IO actions concurrently and discard both
results. The second is a stop-condition.
-}
raceWith :: IO a -> IO b -> IO ()
raceWith a b =
    forConcurrently_
        [void a, void b]
        id

{- | Pack a 'String' into a strict 'ByteString' for a
'BS.isSuffixOf' check.
-}
packBS :: String -> BS.ByteString
packBS = BS.pack . map (fromIntegral . fromEnum)
