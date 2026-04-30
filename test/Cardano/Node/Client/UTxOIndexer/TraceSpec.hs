{- |
Module      : Cardano.Node.Client.UTxOIndexer.TraceSpec
Description : Unit tests for the IndexerEvent stderr renderer
License     : Apache-2.0

Locks down the single-line format produced by
'renderIndexerEvent'. The line shape is what the
'UTxOIndexerReconnectSpec' E2E and operator
container-log greps depend on.
-}
module Cardano.Node.Client.UTxOIndexer.TraceSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Trace (
    IndexerEvent (..),
    StopReason (..),
    renderIndexerEvent,
 )
import Cardano.Node.Client.UTxOIndexer.Types (SlotNo (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec = describe "Cardano.Node.Client.UTxOIndexer.Trace" $ do
    describe "renderIndexerEvent" $ do
        it "started event names the socket and db paths" $ do
            let line =
                    renderIndexerEvent
                        (IndexerStarted "/tmp/idx.sock" (Just "/tmp/idx-db"))
            line
                `containsAll` [ "event=started"
                              , "socketPath=/tmp/idx.sock"
                              , "dbPath=/tmp/idx-db"
                              ]

        it "started event marks db as <in-memory> when no path" $ do
            let line =
                    renderIndexerEvent
                        (IndexerStarted "/tmp/idx.sock" Nothing)
            line
                `containsAll` [ "event=started"
                              , "dbPath=<in-memory>"
                              ]

        it "disconnected event carries the reason" $ do
            let line =
                    renderIndexerEvent
                        (IndexerDisconnected (Text.pack "bearer-closed"))
            line
                `containsAll` [ "event=disconnected"
                              , "reason=bearer-closed"
                              ]

        it "node-replaying event carries attempt and elapsedMs" $ do
            let line = renderIndexerEvent (IndexerNodeReplaying 4 1750)
            line
                `containsAll` [ "event=node-replaying"
                              , "attempt=4"
                              , "elapsedMs=1750"
                              ]

        it "reconnecting event carries attempt and waitMs" $ do
            let line = renderIndexerEvent (IndexerReconnecting 4 750)
            line
                `containsAll` [ "event=reconnecting"
                              , "attempt=4"
                              , "waitMs=750"
                              ]

        it "reconnected event carries resumeSlot and elapsedMs" $ do
            let line =
                    renderIndexerEvent
                        (IndexerReconnected (Just (SlotNo 12345)) 4200)
            line
                `containsAll` [ "event=reconnected"
                              , "resumeSlot=12345"
                              , "elapsedMs=4200"
                              ]

        it "reconnected event with no slot prints <none>" $ do
            let line =
                    renderIndexerEvent
                        (IndexerReconnected Nothing 1200)
            line
                `containsAll` [ "resumeSlot=<none>"
                              , "elapsedMs=1200"
                              ]

        it "stopped event encodes both reason variants" $ do
            renderIndexerEvent (IndexerStopped StoppedNormally)
                `containsAll` ["event=stopped", "reason=normal"]
            renderIndexerEvent (IndexerStopped StoppedAsync)
                `containsAll` ["event=stopped", "reason=async"]

        it "every line starts with the 'indexer ' grep tag" $ do
            let starts = "indexer "
            renderIndexerEvent
                (IndexerDisconnected (Text.pack "x"))
                `startsWith` starts
            renderIndexerEvent
                (IndexerNodeReplaying 1 0)
                `startsWith` starts
            renderIndexerEvent
                (IndexerReconnecting 1 0)
                `startsWith` starts
            renderIndexerEvent
                (IndexerReconnected Nothing 0)
                `startsWith` starts

containsAll :: Text -> [String] -> IO ()
containsAll line =
    mapM_
        ( \tok ->
            (Text.pack tok `Text.isInfixOf` line, tok, line)
                `shouldBe` (True, tok, line)
        )

startsWith :: Text -> String -> IO ()
startsWith line prefix =
    Text.pack prefix
        `Text.isPrefixOf` line
        `shouldBe` True
