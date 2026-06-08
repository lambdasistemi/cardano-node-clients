{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.Adversary.ServerSpec
Description : Unit tests for the cardano-adversary wire types
License     : Apache-2.0

Pins the wire schemas in
@specs/036-cardano-adversary/contracts/control-wire.md@. Pure JSON
encode / decode round-trips — no Unix socket involvement at this
level. PR C will add an end-to-end socket round-trip test alongside
the first real misbehaviour endpoint.
-}
module Cardano.Node.Client.Adversary.ServerSpec (spec) where

import Cardano.Node.Client.Adversary.Types (
    ChainSyncFlapArgs (..),
    ChainSyncFlapDetails (..),
    ChainSyncFlapFailure (..),
    ErrorReason (..),
    ReadyDetails (..),
    Request (..),
    Response (..),
 )
import Data.Aeson (
    decode,
    eitherDecode,
    encode,
    object,
    (.=),
 )
import Data.ByteString.Lazy (ByteString)
import Data.Either (isLeft)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = do
    describe "Request decoding" $ do
        it "parses {\"ready\": null}" $
            decodeReq "{\"ready\":null}"
                `shouldBe` Right ReqReady

        it "parses chain_sync_flap" $
            decodeReq
                "{\"chain_sync_flap\":{\"seed\":12345,\"limit\":100,\"n_conns\":1}}"
                `shouldBe` Right
                    ( ReqChainSyncFlap
                        ChainSyncFlapArgs
                            { csfSeed = 12345
                            , csfLimit = 100
                            , csfNConns = 1
                            }
                    )

        it "rejects {} (no top-level key)" $
            decodeReq "{}" `shouldSatisfy` isLeft'

        it "rejects multi-key envelopes" $
            decodeReq
                "{\"ready\":null,\"chain_sync_flap\":null}"
                `shouldSatisfy` isLeft'

        it "rejects unknown top-level keys" $
            decodeReq
                "{\"surprise\":null}"
                `shouldSatisfy` isLeft'

    describe "Response encoding" $ do
        it "RespReady embeds ReadyDetails as documented" $
            encode
                ( RespReady
                    ReadyDetails
                        { readyOverall = True
                        , readyN2NHandshakeOk = False
                        , readyConfiguredHosts = ["p1.example", "p2.example"]
                        }
                )
                `shouldBe` encode
                    ( object
                        [ "ready" .= True
                        , "details"
                            .= object
                                [ "n2nHandshakeOk" .= False
                                , "configuredHosts"
                                    .= ["p1.example" :: String, "p2.example"]
                                ]
                        ]
                    )

        it "RespNotImplemented uses the documented shape" $
            encode RespNotImplemented
                `shouldBe` encode
                    ( object
                        [ "ok" .= False
                        , "reason" .= ("not-implemented" :: String)
                        ]
                    )

        it "RespError ErrMalformedJson is {\"error\":\"malformed json\"}" $
            encode (RespError ErrMalformedJson)
                `shouldBe` encode
                    ( object ["error" .= ("malformed json" :: String)]
                    )

        it "RespError ErrUnknownRequest is {\"error\":\"unknown request\"}" $
            encode (RespError ErrUnknownRequest)
                `shouldBe` encode
                    ( object ["error" .= ("unknown request" :: String)]
                    )

        it "RespChainSyncFlapOk shape matches control-wire.md" $
            encode
                ( RespChainSyncFlapOk
                    ChainSyncFlapDetails
                        { csfdConnections = 2
                        , csfdPeerNames = ["p1.example", "p2.example"]
                        , csfdLimit = 100
                        }
                )
                `shouldBe` encode
                    ( object
                        [ "ok" .= True
                        , "details"
                            .= object
                                [ "connections" .= (2 :: Int)
                                , "peerNames"
                                    .= ["p1.example" :: String, "p2.example"]
                                , "limit" .= (100 :: Int)
                                ]
                        ]
                    )

        it "RespChainSyncFlapFail no-chain-points-yet" $
            encode (RespChainSyncFlapFail CsffNoChainPointsYet)
                `shouldBe` encode
                    ( object
                        [ "ok" .= False
                        , "reason" .= ("no-chain-points-yet" :: String)
                        ]
                    )

        it "RespChainSyncFlapFail no-chain-points-file" $
            encode (RespChainSyncFlapFail CsffNoChainPointsFile)
                `shouldBe` encode
                    ( object
                        [ "ok" .= False
                        , "reason" .= ("no-chain-points-file" :: String)
                        ]
                    )

        it "RespChainSyncFlapFail no-producers" $
            encode (RespChainSyncFlapFail CsffNoProducers)
                `shouldBe` encode
                    ( object
                        [ "ok" .= False
                        , "reason" .= ("no-producers" :: String)
                        ]
                    )

    describe "Round-trip" $ do
        it "ChainSyncFlapArgs encodes and decodes back to itself" $ do
            let body =
                    ChainSyncFlapArgs
                        { csfSeed = maxBound
                        , csfLimit = 12345
                        , csfNConns = 7
                        }
            decode (encode body) `shouldBe` Just body

        it "ReadyDetails encodes and decodes back to itself" $ do
            let r =
                    ReadyDetails
                        { readyOverall = False
                        , readyN2NHandshakeOk = False
                        , readyConfiguredHosts = ["a", "b", "c"]
                        }
            decode (encode r) `shouldBe` Just r

decodeReq :: ByteString -> Either String Request
decodeReq = eitherDecode

isLeft' :: Either String a -> Bool
isLeft' = isLeft
