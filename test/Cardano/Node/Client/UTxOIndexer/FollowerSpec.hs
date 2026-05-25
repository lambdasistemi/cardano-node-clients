{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.FollowerSpec
Description : Unit tests for the chain-sync follower primitive
License     : Apache-2.0

Exercises 'withChainSyncFollower' against a caller-owned
'IndexerHandle' returned by 'withInMemoryIndexer'. The
follower's reconnect supervisor probes a missing relay
socket and retries forever; the inner action runs to
completion before the bracket cancels the follower thread.

This unit suite proves the API surface — the caller can
write to the same handle the follower will (eventually)
write to, and the readiness 'TVar' is reachable via the
exposed 'STM' action. The "follower actually reaches
readiness after a live chain-sync session" claim is
exercised by the existing
"Cardano.Node.Client.E2E.UTxOIndexerReconnectSpec" E2E
against a devnet node.
-}
module Cardano.Node.Client.UTxOIndexer.FollowerSpec (spec) where

import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (
    defaultReconnectPolicy,
 )
import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Cardano.Node.Client.UTxOIndexer.Follower (
    ChainSyncConfig (..),
    FollowerHandle (..),
    Readiness (..),
    withChainSyncFollower,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    withInMemoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.IndexerOp (
    UtxoOp (..),
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM (atomically)
import Data.ByteString qualified as BS
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer.Follower" $ do
        describe "withChainSyncFollower" $ do
            it
                "brings up against a caller-owned\
                \ in-memory IndexerHandle and exposes a\
                \ FollowerHandle whose initial Readiness\
                \ has no processed/tip slot yet"
                $ withInMemoryIndexer
                $ \idx ->
                    withSystemTempDirectory
                        "follower-spec"
                        $ \dir -> do
                            let cfg = mkCfg (dir <> "/missing.sock")
                            withChainSyncFollower
                                nullN2CTracer
                                cfg
                                idx
                                $ \fh -> do
                                    r <-
                                        atomically
                                            (fhReadiness fh)
                                    rProcessedSlot r
                                        `shouldBe` Nothing
                                    rTipSlot r `shouldBe` Nothing

            it
                "lets the caller continue to write the\
                \ same IndexerHandle via applyAtSlot\
                \ and read it back via snapshotAt while\
                \ the follower thread is alive"
                $ withInMemoryIndexer
                $ \idx ->
                    withSystemTempDirectory
                        "follower-spec"
                        $ \dir -> do
                            let cfg = mkCfg (dir <> "/missing.sock")
                                addr = Address "addr-bytes"
                                txin =
                                    TxIn
                                        (BS.replicate 32 0xAA)
                                        0
                                txout = TxOut "txout-1"
                                bh =
                                    BlockHash
                                        (BS.replicate 32 0xBB)
                            withChainSyncFollower
                                nullN2CTracer
                                cfg
                                idx
                                $ \fh -> do
                                    applyAtSlot
                                        idx
                                        (SlotNo 10)
                                        bh
                                        [ UtxoCreate
                                            txin
                                            addr
                                            txout
                                        ]
                                    snap <- snapshotAt idx addr
                                    snap
                                        `shouldBe` [(txin, txout)]
                                    -- fhAsync is exposed so the
                                    -- caller may 'link' it; we
                                    -- only assert it's typed
                                    -- correctly (no NDJSON
                                    -- server is started — the
                                    -- API signature has no
                                    -- listen-socket parameter).
                                    let _follower ::
                                            Async.Async ()
                                        _follower = fhAsync fh
                                    pure ()

-- ---------------------------------------------------------------------------
-- Helpers

{- | Test 'ChainSyncConfig' parameterised on the relay
socket path. Defaults match the existing 'DaemonSpec.testCfg'
shape so the field set the daemon needs is exercised here
too.
-}
mkCfg :: FilePath -> ChainSyncConfig
mkCfg sock =
    ChainSyncConfig
        { csRelaySocket = sock
        , csNetworkMagic = NetworkMagic 42
        , csByronEpochSlots = 86_400
        , csReadyThresholdSlots = 5
        , csSecurityParamK = 432
        , csReconnectPolicy = defaultReconnectPolicy
        , csProbeConfig = defaultProbeConfig
        }
