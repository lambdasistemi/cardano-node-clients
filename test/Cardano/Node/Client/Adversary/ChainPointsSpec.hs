{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.Adversary.ChainPointsSpec
Description : Unit tests for ChainPoints parser + sampler
License     : Apache-2.0
-}
module Cardano.Node.Client.Adversary.ChainPointsSpec (spec) where

import Cardano.Node.Client.Adversary.ChainPoints (
    generatePoints,
    originPoint,
    parseChainPointSamples,
    readChainPoint,
 )
import Data.List.NonEmpty qualified as NE
import Data.Maybe (isJust, isNothing)
import System.Random (mkStdGen)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = do
    describe "readChainPoint" $ do
        it "parses 'origin'" $
            readChainPoint "origin" `shouldBe` Just originPoint

        it "rejects empty string" $
            readChainPoint "" `shouldSatisfy` isNothing

        it "rejects garbage with no '@'" $
            readChainPoint "deadbeef" `shouldSatisfy` isNothing

        it "rejects non-hex blockHash" $
            readChainPoint "ZZZZ@1234" `shouldSatisfy` isNothing

        it "rejects non-numeric slotNo" $
            readChainPoint "deadbeef@notaslot" `shouldSatisfy` isNothing

        it "accepts a well-formed hex@slot" $
            readChainPoint "deadbeef@1234" `shouldSatisfy` isJust

    describe "parseChainPointSamples" $ do
        it "always prepends origin" $ case parseChainPointSamples "" of
            Just neList -> NE.head neList `shouldBe` originPoint
            Nothing -> error "empty file should still produce a sample list"

        it "rejects a file containing one bad line" $
            parseChainPointSamples "deadbeef@1\nZZZ@2"
                `shouldSatisfy` isNothing

        it "accepts multiple well-formed lines" $
            case parseChainPointSamples "deadbeef@1\n4242@99" of
                Just ne -> NE.length ne `shouldBe` 3 -- origin + two parsed
                Nothing -> error "should parse"

    describe "generatePoints" $ do
        it "returns the sole point repeatedly when input is a singleton" $ do
            let g = mkStdGen 1
                ne = originPoint NE.:| []
                stream = generatePoints g ne
            NE.take 5 stream `shouldBe` replicate 5 originPoint

        it "is deterministic given a fixed seed" $
            case parseChainPointSamples "deadbeef@1\n4242@2" of
                Nothing -> error "should parse"
                Just ne -> do
                    let g1 = mkStdGen 42
                        g2 = mkStdGen 42
                        s1 = NE.take 10 (generatePoints g1 ne)
                        s2 = NE.take 10 (generatePoints g2 ne)
                    s1 `shouldBe` s2

        it "differs given different seeds (with high probability)" $
            case parseChainPointSamples "deadbeef@1\n4242@2\n9999@3" of
                Nothing -> error "should parse"
                Just ne -> do
                    let g1 = mkStdGen 1
                        g2 = mkStdGen 2
                        s1 = NE.take 50 (generatePoints g1 ne)
                        s2 = NE.take 50 (generatePoints g2 ne)
                    (s1 == s2) `shouldBe` False
