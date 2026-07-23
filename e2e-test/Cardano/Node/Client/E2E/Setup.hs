{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.Setup
Description : E2E test helpers for devnet
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.Setup (
    -- * Constants
    devnetMagic,
    genesisDir,

    -- * Devnet configuration
    TargetPV (..),
    DevnetConfig (..),
    defaultDevnetConfig,

    -- * Genesis key
    genesisSignKey,
    genesisAddr,

    -- * Key generation
    mkSignKey,
    keyHashFromSignKey,
    enterpriseAddr,

    -- * Signing
    addKeyWitness,

    -- * Ed25519 primitives (re-exports for downstream test harnesses)

    --
    -- Downstream projects exercising customer-supplied Ed25519 signatures
    -- (for example, a ZK-proof validator that consumes a customer signature
    -- as part of its redeemer) need to verify those bytes with an Ed25519
    -- library that is byte-compatible with the Plutus @VerifyEd25519Signature@
    -- builtin. Exposing the underlying @cardano-crypto-class@ primitives here
    -- keeps the public surface consistent and prevents downstream projects
    -- from depending on @cardano-crypto-class@ directly.
    Ed25519DSIGN,
    SignKeyDSIGN,
    VerKeyDSIGN,
    SigDSIGN,
    verifyDSIGN,
    signDSIGN,
    deriveVerKeyDSIGN,
    rawDeserialiseVerKeyDSIGN,
    rawDeserialiseSignKeyDSIGN,
    rawDeserialiseSigDSIGN,
    rawSerialiseVerKeyDSIGN,
    rawSerialiseSignKeyDSIGN,
    rawSerialiseSigDSIGN,

    -- * Devnet bracket
    assertPV11Enacted,
    withDevnet,
    withDevnetConfig,
    withDevnetFromGenesis,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, poll)
import Data.Maybe (fromMaybe)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Environment (lookupEnv)

import Cardano.Crypto.DSIGN (
    Ed25519DSIGN,
    SigDSIGN,
    SignKeyDSIGN,
    VerKeyDSIGN,
    deriveVerKeyDSIGN,
    rawDeserialiseSigDSIGN,
    rawDeserialiseSignKeyDSIGN,
    rawDeserialiseVerKeyDSIGN,
    rawSerialiseSigDSIGN,
    rawSerialiseSignKeyDSIGN,
    rawSerialiseVerKeyDSIGN,
    signDSIGN,
    verifyDSIGN,
 )
import Cardano.Node.Client.E2E.Devnet (
    addKeyWitness,
    enterpriseAddr,
    genesisAddr,
    genesisSignKey,
    keyHashFromSignKey,
    mkSignKey,
    withCardanoNode,
 )
import Cardano.Node.Client.E2E.Governance (
    assertPV11Enacted,
    enactPV11Transition,
 )
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Types (
    LSQChannel,
    LTxSChannel,
 )

-- | Devnet uses network magic 42.
devnetMagic :: NetworkMagic
devnetMagic = NetworkMagic 42

{- | Path to the checked-in genesis directory.
Override with @E2E_GENESIS_DIR@ env var.
-}
genesisDir :: IO FilePath
genesisDir = do
    mPath <- lookupEnv "E2E_GENESIS_DIR"
    pure $
        fromMaybe
            "e2e-test/genesis"
            mPath

-- | Target protocol version for devnet execution.
data TargetPV = PV10 | PV11
    deriving stock (Eq, Show, Enum, Bounded)

-- | Configuration parameters for devnet setup.
data DevnetConfig = DevnetConfig
    { devnetTargetPV :: TargetPV
    , devnetGenesisDir :: Maybe FilePath
    }
    deriving stock (Eq, Show)

-- | Default devnet configuration (PV10 target, default genesis directory).
defaultDevnetConfig :: DevnetConfig
defaultDevnetConfig =
    DevnetConfig
        { devnetTargetPV = PV10
        , devnetGenesisDir = Nothing
        }

{- | Start a cardano-node devnet with the given configuration, connect via N2C,
run an action, and tear down.
-}
withDevnetConfig ::
    DevnetConfig ->
    (LSQChannel -> LTxSChannel -> IO a) ->
    IO a
withDevnetConfig cfg action = case devnetTargetPV cfg of
    PV10 -> do
        gDir <- maybe genesisDir pure (devnetGenesisDir cfg)
        withDevnetFromGenesis gDir action
    PV11 -> do
        gDir <- maybe genesisDir pure (devnetGenesisDir cfg)
        withDevnetFromGenesis gDir $ \lsq ltxs -> do
            enactPV11Transition lsq ltxs
            let provider = mkN2CProvider lsq
            assertPV11Enacted provider
            action lsq ltxs

{- | Start a cardano-node devnet, connect via N2C,
run an action, and tear down.
-}
withDevnet ::
    (LSQChannel -> LTxSChannel -> IO a) ->
    IO a
withDevnet = withDevnetConfig defaultDevnetConfig

{- | Start a cardano-node devnet from a specific
genesis directory, connect via N2C, run an action,
and tear down.
-}
withDevnetFromGenesis ::
    FilePath ->
    (LSQChannel -> LTxSChannel -> IO a) ->
    IO a
withDevnetFromGenesis gDir action =
    withCardanoNode gDir $ \sock _startMs -> do
        lsqCh <- newLSQChannel 16
        ltxsCh <- newLTxSChannel 16
        nodeThread <-
            async $
                runNodeClient
                    devnetMagic
                    sock
                    lsqCh
                    ltxsCh
        -- Give the N2C connection a moment
        threadDelay 3_000_000
        -- Check the connection is still alive
        status <- poll nodeThread
        case status of
            Just (Left err) ->
                error $
                    "Node connection failed: "
                        <> show err
            Just (Right (Left err)) ->
                error $
                    "Node connection error: "
                        <> show err
            Just (Right (Right ())) ->
                error
                    "Node connection closed \
                    \unexpectedly"
            Nothing -> pure ()
        result <- action lsqCh ltxsCh
        cancel nodeThread
        pure result
