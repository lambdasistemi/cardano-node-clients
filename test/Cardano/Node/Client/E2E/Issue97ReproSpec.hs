{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.Issue97ReproSpec
Description : Regression for issue #97 (bearer-closed escape)
License     : Apache-2.0

Locks down the upstream behaviour that motivates the
in-process reconnect supervisor described in
<https://github.com/lambdasistemi/cardano-node-clients/issues/97>:

> An unhandled @network-mux@ @BearerClosed@ exception
> escapes 'runChainSyncN2C' when its peer (the relay
> it's chain-synced to) closes the socket.

The test spawns 'runChainSyncN2C' with a minimal no-op
'Follower' against a real devnet relay, asks the test
harness to terminate-and-respawn that relay, and asserts
that the chain-sync 'Async' resolves to a 'Left' carrying
a @BearerClosed@ exception. This is the contract that
justifies layering a supervisor (sync-exception catch +
backoff retry) on top.

If the supervisor is added later to 'runChainSyncN2C'
itself (rather than as an external wrapper), this test
will need updating; that is the intended signal.
-}
module Cardano.Node.Client.E2E.Issue97ReproSpec (spec) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Node.Client.E2E.Devnet (withRestartableCardanoNode)
import Cardano.Node.Client.E2E.Setup (genesisDir)
import Cardano.Node.Client.N2C.ChainSync (
    Fetched,
    HeaderPoint,
    mkChainSyncN2C,
    runChainSyncN2C,
 )
import ChainFollower (
    Follower (..),
    Intersector (..),
    ProgressOrRewind (..),
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (
    poll,
    waitCatch,
    withAsync,
 )
import Control.Exception (SomeException)
import Control.Tracer (nullTracer)
import Data.Char (isAsciiUpper)
import Data.List (isInfixOf)
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point qualified as Network.Point
import System.IO (hPutStrLn, stderr)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    shouldSatisfy,
 )

spec :: Spec
spec =
    describe "issue #97 — BearerClosed escape from runChainSyncN2C" $
        it
            "runChainSyncN2C terminates with a BearerClosed-like \
            \exception when the upstream relay restarts"
            runRepro

runRepro :: IO ()
runRepro = do
    gDir <- genesisDir
    withRestartableCardanoNode gDir $ \nodeSock _startMs restart -> do
        let chainSync =
                runChainSyncN2C
                    (EpochSlots 42)
                    (NetworkMagic 42)
                    nodeSock
                    ( mkChainSyncN2C
                        nullTracer
                        nullTracer
                        noopIntersector
                        [Network.Point Network.Point.Origin]
                    )
        withAsync chainSync $ \chainAsync -> do
            -- Let chain-sync settle into a normal
            -- roll-forward stream before the disturbance.
            threadDelay 3_000_000
            poll chainAsync >>= \case
                Just outcome ->
                    expectationFailure $
                        "chain-sync exited prematurely (before \
                        \restart) with: "
                            <> show outcome
                Nothing -> pure ()
            hPutStrLn
                stderr
                "[issue97-regression] restarting relay..."
            restart
            -- Give the chain-sync thread time to observe
            -- the bearer close. In practice the exception
            -- arrives within milliseconds; the 5 s budget
            -- keeps the test robust on slow machines.
            threadDelay 5_000_000
            outcome <- waitCatch chainAsync
            outcome `shouldSatisfy` isBearerClosedFailure

{- | A no-op intersector + follower. Accepts every roll-forward
and rolls back to whatever point the server proposes.
-}
noopIntersector :: Intersector HeaderPoint Network.SlotNo Fetched
noopIntersector =
    Intersector
        { intersectFound = const (pure noopFollower)
        , intersectNotFound =
            pure (noopIntersector, [Network.Point Network.Point.Origin])
        }

noopFollower :: Follower HeaderPoint Network.SlotNo Fetched
noopFollower = self
  where
    self =
        Follower
            { rollForward = \_ _ -> pure self
            , rollBackward = const (pure (Progress self))
            }

{- | Predicate matching the failure mode in issue #97. We don't
pin the concrete exception type (network-mux's internal
constructors aren't exported in a stable way), but we do require:

  * the chain-sync 'Async' resolved with a 'Left' (i.e.
    the exception escaped 'runChainSyncN2C''s own catch path), and

  * the rendered exception text contains @"bearer closed"@ or
    @"BearerClosed"@.
-}
isBearerClosedFailure :: Either SomeException a -> Bool
isBearerClosedFailure (Right _) = False
isBearerClosedFailure (Left e) =
    let s = show e
        cleaned =
            -- Don't depend on case in the exception text.
            map toLowerAscii s
     in "bearer closed" `isInfixOf` cleaned
            || "bearerclosed" `isInfixOf` cleaned
            || hasMuxRuntime e
  where
    toLowerAscii c
        | isAsciiUpper c = toEnum (fromEnum c + 32)
        | otherwise = c

{- | Treat any 'SomeException' whose rendered text mentions
@network-mux@ as a positive match for the issue-97 failure
mode. Guards against the BearerClosed constructor being
renamed in a future @ouroboros-network@ release.
-}
hasMuxRuntime :: SomeException -> Bool
hasMuxRuntime e = "network-mux" `isInfixOf` show e
