{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Cardano.Node.Client.E2E.ChainPopulator
Description : Deterministic chain population via CPS state machine
License     : Apache-2.0

Run a 'ChainPopulator' state machine against a devnet
node. The populator receives each block and returns
transactions to submit plus a continuation. The runner
signs, submits, and accumulates all blocks. Returns
the full chain when the populator signals done.
-}
module Cardano.Node.Client.E2E.ChainPopulator (
    -- * State machine
    ChainPopulator (..),
    PopulatorNext (..),

    -- * Runner
    populateChain,
) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Crypto.DSIGN (
    Ed25519DSIGN,
    SignKeyDSIGN,
 )
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (Tx)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.E2E.Setup (
    addKeyWitness,
 )
import Cardano.Node.Client.N2C.ChainSync (
    Fetched (..),
    HeaderPoint,
    mkChainSyncN2C,
    runChainSyncN2C,
 )
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider (Provider (..))
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.Types (Block)
import ChainFollower (
    Follower (..),
    Intersector (..),
    ProgressOrRewind (..),
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, race)
import Control.Concurrent.STM (
    atomically,
    newEmptyTMVarIO,
    putTMVar,
    readTMVar,
 )
import Control.Exception (SomeException, throwIO, try)
import Control.Tracer (nullTracer)
import Ouroboros.Network.Block (
    Point (..),
    SlotNo,
 )
import Ouroboros.Network.Magic (NetworkMagic)
import Ouroboros.Network.Point (WithOrigin (..))

{- | CPS state machine for chain population.

Receives each block as it arrives from ChainSync.
The populator tracks its own UTxO state internally.
Returns unsigned transactions to submit plus the
next state, or 'Close' to stop and receive the
accumulated blocks (or an error) via a callback.
-}
newtype ChainPopulator = ChainPopulator
    { onBlock ::
        PParams ConwayEra ->
        Block ->
        IO PopulatorNext
    }

-- | Result of a populator step.
data PopulatorNext
    = {- | Submit these transactions and continue
      with the next populator state.
      -}
      Continue [Tx ConwayEra] ChainPopulator
    | {- | Submit these final transactions, then
      deliver the accumulated blocks (or error)
      to the callback.
      -}
      Close
        [Tx ConwayEra]
        (Either SomeException [Block] -> IO ())

{- | Run a chain populator against a devnet node.

Connects ChainSync + LTxS to the node. For each
block received via ChainSync:

1. Pass the block to the populator's 'onBlock'
2. Sign and submit returned transactions
3. Accumulate the block

State is threaded through the 'Follower' closure —
no mutable refs for blocks or populator state. Only
a 'TMVar' for signalling completion to the main
thread.

Returns the full list of blocks when the populator
signals done ('Nothing').
-}
populateChain ::
    -- | Path to node Unix socket
    FilePath ->
    -- | Network magic
    NetworkMagic ->
    -- | Address to query initial UTxOs
    Addr ->
    -- | Signing key for transactions
    SignKeyDSIGN Ed25519DSIGN ->
    -- | Build a populator from initial PParams and UTxOs
    ( PParams ConwayEra ->
      [(TxIn, TxOut ConwayEra)] ->
      ChainPopulator
    ) ->
    IO ()
populateChain socketPath magic addr signKey mkPopulator = do
    -- Set up LSQ + LTxS for queries and submission
    lsqCh <- newLSQChannel 16
    ltxsCh <- newLTxSChannel 16
    nodeThread <-
        async $
            runNodeClient magic socketPath lsqCh ltxsCh
    threadDelay 3_000_000

    let provider = mkN2CProvider lsqCh
        submitter = mkN2CSubmitter ltxsCh

    -- Query protocol params and initial UTxOs once
    pp <- queryProtocolParams provider
    utxos <- queryUTxOs provider addr
    let initPopulator = mkPopulator pp utxos

    -- Signal: the populator's Close callback has been
    -- called — the main thread can proceed to cleanup.
    doneVar <- newEmptyTMVarIO

    let
        -- Follower with state in the closure:
        -- accumulated blocks (reversed) and current
        -- populator.
        go ::
            [Block] ->
            ChainPopulator ->
            Follower HeaderPoint SlotNo Fetched
        go blocks pop =
            Follower
                { rollForward = \fetched _ -> do
                    let block = fetchedBlock fetched
                        blocks' = block : blocks
                    result <- try @SomeException $ do
                        step <- onBlock pop pp block
                        case step of
                            Continue txs next -> do
                                mapM_ (signAndSubmit submitter signKey) txs
                                pure $ go blocks' next
                            Close txs callback -> do
                                mapM_ (signAndSubmit submitter signKey) txs
                                callback (Right (reverse blocks'))
                                atomically $ putTMVar doneVar ()
                                pure idle
                    case result of
                        Left err -> do
                            atomically $ putTMVar doneVar ()
                            throwIO err
                        Right follower -> pure follower
                , rollBackward = \_ ->
                    pure $ Progress $ go blocks pop
                }

        -- After Close, just idle until cleanup.
        idle :: Follower HeaderPoint SlotNo Fetched
        idle =
            Follower
                { rollForward = \_ _ -> pure idle
                , rollBackward = \_ -> pure $ Progress idle
                }

        mkIntersector :: Intersector HeaderPoint SlotNo Fetched
        mkIntersector =
            Intersector
                { intersectFound = \_ ->
                    pure $ go [] initPopulator
                , intersectNotFound =
                    pure (mkIntersector, [])
                }

    -- Run ChainSync in background
    syncThread <-
        async $
            runChainSyncN2C
                (EpochSlots 42)
                magic
                socketPath
                ( mkChainSyncN2C
                    nullTracer
                    nullTracer
                    mkIntersector
                    [Point Origin]
                )

    -- Wait for populator to close or timeout (10 min)
    result <-
        race
            (threadDelay 600_000_000)
            (atomically $ readTMVar doneVar)

    -- Cleanup
    cancel syncThread
    cancel nodeThread

    case result of
        Left () ->
            error "populateChain: timed out"
        Right () -> pure ()

-- | Sign a transaction and submit it.
signAndSubmit ::
    Submitter IO ->
    SignKeyDSIGN Ed25519DSIGN ->
    Tx ConwayEra ->
    IO ()
signAndSubmit submitter signKey tx = do
    let signed = addKeyWitness signKey tx
    result <- submitTx submitter signed
    case result of
        Submitted _ -> pure ()
        Rejected reason ->
            error $
                "signAndSubmit: rejected: "
                    <> show reason
