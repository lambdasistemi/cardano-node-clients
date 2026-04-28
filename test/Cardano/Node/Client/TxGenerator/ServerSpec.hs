{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.ServerSpec
Description : Unit tests for the tx-generator wire types
License     : Apache-2.0

Pins the wire schemas in
@specs/034-cardano-tx-generator/contracts/control-wire.md@.
Pure JSON encode / decode round-trips — no Unix socket
involvement at this level. The end-to-end socket
round-trip is covered by T007's E2E once the Main
executable mounts the server.
-}
module Cardano.Node.Client.TxGenerator.ServerSpec (spec) where

import Cardano.Node.Client.TxGenerator.Types (
    FailureReason (..),
    ReadyResponse (..),
    RefillRequest (..),
    Request (..),
    SnapshotResponse (..),
    TransactRequest (..),
    TransactResponse (..),
 )
import Data.Aeson (
    Value (Object),
    eitherDecode,
    object,
    toJSON,
    (.=),
 )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy (ByteString)
import Data.Set qualified as Set
import Data.Text (Text)
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "TxGenerator.Server (wire)" $ do
    describe "request parsing" $ do
        it "parses {\"ready\":null} as ReqReady" $
            decodeReq "{\"ready\":null}"
                `shouldBe` Right ReqReady

        it "parses {\"snapshot\":null} as ReqSnapshot" $
            decodeReq "{\"snapshot\":null}"
                `shouldBe` Right ReqSnapshot

        it "parses a transact body" $
            decodeReq
                "{\"transact\":{\"seed\":17,\"fanout\":6,\
                \\"prob_fresh\":0.5}}"
                `shouldBe` Right
                    ( ReqTransact
                        TransactRequest
                            { txReqSeed = 17
                            , txReqFanout = 6
                            , txReqProbFresh = 0.5
                            }
                    )

        it "parses a refill body" $
            decodeReq "{\"refill\":{\"seed\":42}}"
                `shouldBe` Right
                    (ReqRefill (RefillRequest 42))

        it "rejects {} (no top-level key)" $
            decodeReq "{}" `shouldSatisfy` isLeft'

        it "rejects multi-key envelopes" $
            decodeReq
                "{\"ready\":null,\"snapshot\":null}"
                `shouldSatisfy` isLeft'

        it "rejects ready: <non-null>" $
            decodeReq
                "{\"ready\":\"not null\"}"
                `shouldSatisfy` isLeft'

        it "rejects unknown top-level keys" $
            decodeReq
                "{\"surprise\":null}"
                `shouldSatisfy` isLeft'

    describe "response encoding" $ do
        it "ReadyResponse uses ready/indexReady/faucetUtxosKnown" $
            toJSON
                ReadyResponse
                    { readyReady = True
                    , readyIndexReady = True
                    , readyFaucetUtxosKnown = False
                    }
                `shouldBe` object
                    [ "ready" .= True
                    , "indexReady" .= True
                    , "faucetUtxosKnown" .= False
                    ]

        it "SnapshotResponse uses the documented shape" $
            toJSON
                SnapshotResponse
                    { snapPopulationSize = 137
                    , snapP10Lovelace = Just 1850000
                    , snapP50Lovelace = Just 2050000
                    , snapP90Lovelace = Just 49850000000
                    , snapTipSlot = Just 14502
                    , snapLastTxId = Just "abcd"
                    }
                `shouldBe` object
                    [ "populationSize" .= (137 :: Int)
                    , "p10_lovelace" .= (1850000 :: Int)
                    , "p50_lovelace" .= (2050000 :: Int)
                    , "p90_lovelace" .= (49850000000 :: Int)
                    , "tipSlot" .= (14502 :: Int)
                    , "lastTxId" .= ("abcd" :: Text)
                    ]

        it "TransactOk has the expected key set" $ do
            let actual =
                    Set.fromList
                        ( keysOf
                            ( toJSON
                                TransactOk
                                    { txOkTxId = "deadbeef"
                                    , txOkSrc = 17
                                    , txOkDsts = [42, 43]
                                    , txOkValuesLovelace =
                                        [2000000, 1850000]
                                    , txOkFreshCount = 1
                                    , txOkAwaited = True
                                    }
                            )
                        )
            actual
                `shouldBe` Set.fromList
                    [ "ok"
                    , "txId"
                    , "src"
                    , "dsts"
                    , "values_lovelace"
                    , "fresh_count"
                    , "awaited"
                    ]

        it "TransactFail NoPickableSource → no-pickable-source" $
            toJSON (TransactFail NoPickableSource)
                `shouldBe` object
                    [ "ok" .= False
                    , "reason" .= ("no-pickable-source" :: Text)
                    ]

        it "TransactFail IndexNotReady → index-not-ready" $
            toJSON (TransactFail IndexNotReady)
                `shouldBe` object
                    [ "ok" .= False
                    , "reason" .= ("index-not-ready" :: Text)
                    ]

        it "TransactFail FaucetExhausted → faucet-exhausted" $
            toJSON (TransactFail FaucetExhausted)
                `shouldBe` object
                    [ "ok" .= False
                    , "reason" .= ("faucet-exhausted" :: Text)
                    ]

        it "TransactFail FaucetNotKnown → faucet-not-known" $
            toJSON (TransactFail FaucetNotKnown)
                `shouldBe` object
                    [ "ok" .= False
                    , "reason" .= ("faucet-not-known" :: Text)
                    ]

        it "TransactFail (SubmitRejected …) carries the reason text" $
            toJSON
                ( TransactFail
                    (SubmitRejected "ValueNotConserved")
                )
                `shouldBe` object
                    [ "ok" .= False
                    , "reason"
                        .= ( "submit-rejected: ValueNotConserved" ::
                                Text
                           )
                    ]

decodeReq :: ByteString -> Either String Request
decodeReq = eitherDecode

keysOf :: Value -> [Text]
keysOf (Object km) = map Key.toText (KeyMap.keys km)
keysOf _ = []

isLeft' :: Either a b -> Bool
isLeft' (Left _) = True
isLeft' _ = False
