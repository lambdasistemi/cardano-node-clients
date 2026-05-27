{- |
Module      : Cardano.Node.Client.UTxOIndexer.DaemonSpec
Description : Regression tests for the supervisor → ReadyStatus
              transition in 'Cardano.Node.Client.UTxOIndexer.Daemon'.
License     : Apache-2.0

Covers issue #119: under fault injection, the supervisor flips
@UpstreamStatus@ from @Connected@ → @Disconnected@ → @Connected@
without any 'rollForward' in between (because the chain hasn't
moved past the indexer's last seen tip while the relay was
restarting). With the old asymmetric handler, @rsReady@ was
clobbered to @False@ on disconnect and never restored on
reconnect — the next 'updateReady' is the only writer of the
field. This test asserts the symmetric behavior:

  * disconnect clobbers @rsReady = False@, preserves slot fields
  * reconnect re-derives @rsReady@ from @rsSlotsBehind@ against
    @dcReadyThresholdSlots@.
-}
module Cardano.Node.Client.UTxOIndexer.DaemonSpec (spec) where

import Cardano.Node.Client.BlockIndexer.Readiness (
    slotLag,
 )
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Reconnect (
    DisconnectInfo (..),
    UpstreamStatus (..),
    defaultReconnectPolicy,
 )
import Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    applyUpstreamStatus,
 )
import Cardano.Node.Client.UTxOIndexer.Server (ReadyStatus (..))
import Cardano.Node.Client.UTxOIndexer.Types (SlotNo (..))
import Data.Text qualified as Text
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = do
    describe "slotLag"
        $ it
            "clamps lag to zero when processed slot is ahead of tip"
        $ slotLag unSlotNo (Just (SlotNo 70)) (Just (SlotNo 60))
            `shouldBe` Just 0

    describe "applyUpstreamStatus" $ do
        it "Disconnected clobbers rsReady to False, preserves slot fields" $ do
            let rs0 = caughtUp
                rs1 = applyUpstreamStatus testCfg disconnect rs0
            rsReady rs1 `shouldBe` False
            rsTipSlot rs1 `shouldBe` rsTipSlot rs0
            rsProcessedSlot rs1 `shouldBe` rsProcessedSlot rs0
            rsSlotsBehind rs1 `shouldBe` rsSlotsBehind rs0
            rsUpstream rs1 `shouldBe` disconnect

        it "Connected re-derives rsReady=True when slotsBehind is at or under threshold" $ do
            -- Regression for issue #119 — without the
            -- re-derive, rsReady stayed at False after the
            -- disconnect/reconnect cycle until the next
            -- rollForward.
            let rs0 = caughtUp{rsReady = False, rsUpstream = disconnect}
                rs1 = applyUpstreamStatus testCfg UpstreamConnected rs0
            rsReady rs1 `shouldBe` True
            rsUpstream rs1 `shouldBe` UpstreamConnected
            rsTipSlot rs1 `shouldBe` rsTipSlot rs0
            rsProcessedSlot rs1 `shouldBe` rsProcessedSlot rs0
            rsSlotsBehind rs1 `shouldBe` rsSlotsBehind rs0

        it "Connected leaves rsReady=False when slotsBehind exceeds threshold" $ do
            let rs0 =
                    caughtUp
                        { rsReady = False
                        , rsUpstream = disconnect
                        , rsSlotsBehind = Just 100
                        , rsProcessedSlot = Just (SlotNo 60)
                        , rsTipSlot = Just (SlotNo 160)
                        }
                rs1 = applyUpstreamStatus testCfg UpstreamConnected rs0
            rsReady rs1 `shouldBe` False
            rsUpstream rs1 `shouldBe` UpstreamConnected
            rsSlotsBehind rs1 `shouldBe` Just 100

        it "Connected leaves rsReady=False when slot fields are unset (never rolled forward)" $ do
            let rs0 =
                    ReadyStatus
                        { rsReady = False
                        , rsTipSlot = Nothing
                        , rsProcessedSlot = Nothing
                        , rsSlotsBehind = Nothing
                        , rsUpstream = disconnect
                        }
                rs1 = applyUpstreamStatus testCfg UpstreamConnected rs0
            rsReady rs1 `shouldBe` False
            rsUpstream rs1 `shouldBe` UpstreamConnected

        it "disconnect → reconnect cycle on a caught-up indexer is idempotent" $ do
            -- The full sequence the supervisor exhibits during
            -- a fault: connected → disconnect → connected.
            let rs0 = caughtUp
                rs1 = applyUpstreamStatus testCfg disconnect rs0
                rs2 = applyUpstreamStatus testCfg UpstreamConnected rs1
            rsReady rs0 `shouldBe` True
            rsReady rs1 `shouldBe` False
            rsReady rs2 `shouldBe` True
            rsTipSlot rs2 `shouldBe` rsTipSlot rs0

-- Test fixtures -----------------------------------------------------

testCfg :: DaemonConfig
testCfg =
    DaemonConfig
        { dcRelaySocket = "/dev/null"
        , dcListenSocket = "/dev/null"
        , dcNetworkMagic = 42
        , dcByronEpochSlots = 86_400
        , dcReadyThresholdSlots = 5
        , dcSecurityParamK = 432
        , dcDbPath = Nothing
        , dcReconnectPolicy = defaultReconnectPolicy
        , dcProbeConfig = defaultProbeConfig
        }

caughtUp :: ReadyStatus
caughtUp =
    ReadyStatus
        { rsReady = True
        , rsTipSlot = Just (SlotNo 60)
        , rsProcessedSlot = Just (SlotNo 60)
        , rsSlotsBehind = Just 0
        , rsUpstream = UpstreamConnected
        }

disconnect :: UpstreamStatus
disconnect =
    UpstreamDisconnected
        DisconnectInfo
            { diReason = Text.pack "test-eviction"
            , diAttempt = 1
            , diSinceMs = 0
            }
