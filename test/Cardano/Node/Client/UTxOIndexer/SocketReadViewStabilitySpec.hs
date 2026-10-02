{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.SocketReadViewStabilitySpec
Description : Runtime byte oracle for all legacy socket endpoints
License     : Apache-2.0

The accepted-base server differs only in module name. Both servers receive
identical lines over quiescent real stores and fixed disclosure/readiness.
Equality includes LF and EOF, without normalizing any disclosure fields.
-}
module Cardano.Node.Client.UTxOIndexer.SocketReadViewStabilitySpec (spec) where

import Cardano.Node.Client.UTxOIndexer.Columns (Cols (..))
import Cardano.Node.Client.UTxOIndexer.Indexer (IndexerHandle (..), ReadQuery (..))
import Cardano.Node.Client.UTxOIndexer.PreReadViewServer qualified as Pre
import Cardano.Node.Client.UTxOIndexer.Server qualified as Cur
import Cardano.Node.Client.UTxOIndexer.SocketViewFixture
import Cardano.Node.Client.UTxOIndexer.Types (AddrKey (..), Address (..), PolicyId (..), TxOut (..))
import Cardano.Node.Client.UTxOIndexer.WireClient (assetLine, encodeLine, hex, requestLine, withSocketServer)
import Control.Monad (forM_, unless)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Database.KV.Transaction (delete, insert, runTransaction)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.QuickCheck (Args (..), elements, forAll, ioProperty, isSuccess, output, quickCheckWithResult, stdArgs)

-- | Generated and exhaustive representative byte checks, plus EOF controls.
spec :: Spec
spec = describe "utxo-indexer socket read view legacy bytes" $ do
    it "keeps all four endpoints and ambiguous parser precedence byte-identical" $
        forM_ backends $ \backend -> forM_ [0 .. 5 :: Int] $ \state -> withBackend backend $ \h runner -> do
            case state of
                0 -> pure ()
                _ -> seed h
            runTransaction runner $ case state of
                2 -> delete MetaCol "asset-index"
                3 -> insert MetaCol "asset-index-rebuild" "in progress"
                4 -> delete AddressIndex (AddrKey addrA (tx 0x55))
                5 -> insert AddressIndex (AddrKey addrA (tx 0x55)) (TxOut "invalid")
                _ -> pure ()
            pairs h $ \old cur -> do
                forM_ linesToCompare $ \line -> do
                    (before, after) <- ask old cur line
                    sameBytes before after `shouldBe` Right ()
                    BS.last before `shouldBe` 10
                result <-
                    quickCheckWithResult
                        stdArgs{maxSuccess = 200, chatty = False}
                        ( forAll
                            (elements generatedLines)
                            ( \line -> ioProperty $ do
                                (before, after) <- ask old cur line
                                pure (sameBytes before after == Right ())
                            )
                        )
                unless (isSuccess result) (expectationFailure (output result))
                putStrLn ("LEGACY-BYTES backend=" <> backend <> " state=" <> show state <> " exhaustive=" <> show (length linesToCompare) <> " generated=200 LF/EOF=observed")

    it "rejects every changed byte in representative real legacy responses" $
        withBackend "in-memory" $ \h _ -> do
            seed h
            pairs h $ \old cur -> do
                checked <- newIORef (0 :: Int)
                forM_ linesToCompare $ \line -> do
                    (before, after) <- ask old cur line
                    sameBytes before after `shouldBe` Right ()
                    forM_ [0 .. BS.length after - 1] $ \i -> do
                        let changed = BS.take i after <> BS.singleton (BS.index after i `xor` 1) <> BS.drop (i + 1) after
                        sameBytes before changed `shouldSatisfy` either (const True) (const False)
                        modifyIORef' checked (+ 1)
                count <- readIORef checked
                count `shouldSatisfy` (> 100)
                putStrLn ("LEGACY-BYTE-CONTROL rejected=" <> show count)

    it "keeps the inherited storage-exception EOF path for every legacy storage endpoint" $
        withBackend "in-memory" $ \h _ -> do
            let broken = h{snapshotAt = \_ -> fail "storage exception", assetUtxos = \_ _ -> fail "storage exception", awaitTxIn = \_ _ -> fail "storage exception"}
            pairs broken $ \old cur -> forM_ [addressLine, assetLine (unPolicyId policyA) "tok", awaitLine True] $ \line -> do
                requestLine old line `shouldReturn` BS.empty
                requestLine cur line `shouldReturn` BS.empty

-- Test the same comparator used for real responses, with every byte mutated.
sameBytes :: ByteString -> ByteString -> Either String ()
sameBytes old cur
    | old == cur = Right ()
    | otherwise = Left ("legacy bytes changed: baseline " <> show old <> "; candidate " <> show cur)

pairs :: IndexerHandle -> (FilePath -> FilePath -> IO a) -> IO a
pairs h action = withSocketServer (\p -> Pre.runServer p h disclosure (pure readyFixed)) $ \old ->
    withSocketServer (\p -> Cur.runServer p h disclosure (pure readyFixed)) (action old)

ask :: FilePath -> FilePath -> ByteString -> IO (ByteString, ByteString)
ask old cur line = (,) <$> requestLine old line <*> requestLine cur line

addressLine :: ByteString
addressLine = encodeLine ["utxos_at" .= hex (unAddress addrA)]

awaitLine :: Bool -> ByteString
awaitLine present = encodeLine ["await" .= wireTxIn (if present then tx 0x55 else tx 99), "timeout_seconds" .= (0 :: Int)]

linesToCompare :: [ByteString]
linesToCompare =
    [ addressLine
    , encodeLine ["utxos_at" .= ("" :: Text)]
    , encodeLine ["utxos_at" .= hex (unAddress addrB)]
    , encodeLine ["ready" .= Aeson.Null]
    , awaitLine True
    , awaitLine False
    , assetLine (unPolicyId policyA) "tok"
    , assetLine (unPolicyId policyA) "absent"
    , assetLine (BS.replicate 27 1) "tok"
    , "not json"
    , "[]"
    , "{}"
    , "null"
    , encodeLine ["utxos_at" .= ("zz" :: Text)]
    , encodeLine ["await" .= ("bad" :: Text)]
    ]
        <> generatedLines

-- Cartesian lines systematically exercise legacy fallback/acceptance alongside
-- both valid and invalid new batches. None exempts InvalidAssetQuery.
generatedLines :: [ByteString]
generatedLines =
    [encodeLine (legacy <> batch <> extra) | legacy <- legacyObjects, batch <- newKeys, extra <- [[], ["unknown" .= True]]]
  where
    legacyObjects =
        [ ["utxos_at" .= hex (unAddress addrA)]
        , ["utxos_at" .= ("zz" :: Text), "ready" .= True]
        , ["utxos_at" .= Aeson.Null, "await" .= wireTxIn (tx 0x55), "timeout_seconds" .= (0 :: Int)]
        , ["ready" .= Aeson.Null, "await" .= ("bad" :: Text)]
        , ["await" .= ("bad" :: Text), "utxos_with_asset" .= assetObject]
        , ["utxos_with_asset" .= assetObject]
        , ["utxos_with_asset" .= Aeson.Null]
        , ["utxos_at" .= ("zz" :: Text), "utxos_with_asset" .= Aeson.object []]
        ]
    assetObject = Aeson.object ["policy_id" .= hex (unPolicyId policyA), "asset_name" .= ("746f6b" :: Text)]
    newKeys = [[], ["read_view" .= [queryValue (AddressQuery addrA)]], ["read_view" .= Aeson.Null]]
