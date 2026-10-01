{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.DisclosureStabilitySpec
Description : The disclosure adds members and changes no other byte
License     : Apache-2.0

Adding @network@, @coverage@, @freshness@ and @limits@ to the asset
answer must leave every other byte on the socket as it was. The
expected bytes are produced at run time by the server as it shipped
before the disclosure:
"Cardano.Node.Client.UTxOIndexer.PreDisclosureServer" is that earlier
@Server@ source with only its module name changed. Both servers listen
on their own socket over one indexer and one readiness sample, the
current one also carrying a last-progress time the earlier one never
saw, and receive the same request line.

* A success asset answer of the current server is the earlier answer
  with exactly the four disclosure members inserted before its v1
  members: its bytes are @{@, the four members, a comma, then the
  earlier answer's bytes after its @{@.
* Every other answer — @utxos_at@, @ready@, @await@,
  @invalid_asset_query@, @asset_index_unavailable@, malformed lines —
  is byte-identical.
-}
module Cardano.Node.Client.UTxOIndexer.DisclosureStabilitySpec (spec) where

import Cardano.Crypto.Hash.Class (Hash (UnsafeHash))
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Credential (
    Credential (KeyHashObj),
    StakeReference (StakeRefNull),
 )
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value qualified as Mary
import Cardano.Node.Client.N2C.Reconnect (
    DisconnectInfo (..),
    UpstreamStatus (..),
 )
import Cardano.Node.Client.UTxOIndexer.Disclosure (
    AddressCoverage (..),
    Coverage (..),
    CoverageStart (..),
    Disclosure (..),
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    UtxoOp (..),
    withInMemoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.PreDisclosureServer qualified as Pre
import Cardano.Node.Client.UTxOIndexer.Server qualified as Cur
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Cardano.Node.Client.UTxOIndexer.WireClient (
    assetLine,
    encodeLine,
    hex,
    requestLine,
    withSocketServer,
 )
import Control.Monad (forM_, unless, when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Text (Text)
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Word (Word16, Word64, Word8)
import System.Timeout (timeout)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldSatisfy,
 )
import Test.QuickCheck (
    Args (chatty, maxSuccess),
    Gen,
    Property,
    checkCoverage,
    choose,
    counterexample,
    cover,
    elements,
    forAll,
    frequency,
    ioProperty,
    isSuccess,
    oneof,
    output,
    quickCheckWithResult,
    stdArgs,
 )
import Test.QuickCheck qualified as QC

spec :: Spec
spec = describe "utxo-indexer socket: the disclosure changes no other byte" $ do
    it "answers every request line promptly on both servers over every store" $
        withServerPairs $ \pairs -> do
            at <- getCurrentTime
            forM_ pairs $ \pair ->
                forM_ (requestLines pair) $ \line -> do
                    let c = Case pair (Readiness True (Just 20) (Just 9) (Just 11) Nothing at) line
                    answered <- timeout 10_000_000 (askBoth c)
                    case answered of
                        Just _ -> pure ()
                        Nothing ->
                            expectationFailure
                                ("no answer within 10 s on the " <> show pair <> ": " <> show line)

    it "answers every request as the pre-disclosure server, plus the four members on asset success" $
        withServerPairs $ \pairs -> do
            result <-
                quickCheckWithResult
                    stdArgs{maxSuccess = 400, chatty = False}
                    (checkCoverage (forAll (genCase pairs) answersAlike))
            unless (isSuccess result) (expectationFailure (output result))

    it "detects a change of any single byte outside the disclosure members" $
        withServerPairs $ \pairs -> do
            at <- getCurrentTime
            checked <-
                sum
                    <$> traverse (flipsDetected at) [(p, l) | p <- pairs, l <- controlLines p]
            checked `shouldSatisfy` (> 0)

-- * Comparison

data Shape = AssetSuccess | Unchanged
    deriving stock (Eq, Show)

{- | 'Nothing' when the current answer is the earlier one: identical
bytes, or for an asset success, the earlier bytes after exactly the
four disclosure members.
-}
divergence :: ByteString -> ByteString -> Either String Shape
divergence pre cur
    | isAssetSuccess pre = do
        let v1Tail = BS.drop 1 pre
            (front, back) = BS.splitAt (BS.length cur - BS.length v1Tail) cur
        unless (back == v1Tail) $
            Left ("v1 members differ: pre " <> show pre <> ", now " <> show cur)
        members <- case BS.unsnoc front of
            Just (m, 0x2C) -> Right (m <> "}")
            _ -> Left ("no member list before the v1 members: " <> show cur)
        case Aeson.decodeStrict' members of
            Just (Aeson.Object o)
                | sort (map Key.toText (KM.keys o)) == disclosureKeys ->
                    Right AssetSuccess
            other ->
                Left ("disclosure members " <> show other <> " in " <> show cur)
    | pre == cur = Right Unchanged
    | otherwise =
        Left ("bytes differ: pre " <> show pre <> ", now " <> show cur)

disclosureKeys :: [Text]
disclosureKeys = ["coverage", "freshness", "limits", "network"]

isAssetSuccess :: ByteString -> Bool
isAssetSuccess resp = case Aeson.decodeStrict' resp of
    Just (Aeson.Object o) -> KM.member "point" o && KM.member "utxos" o
    _ -> False

answersAlike :: Case -> Property
answersAlike c = ioProperty $ do
    (pre, cur) <- askBoth c
    let shape = either (const Nothing) Just (divergence pre cur)
    pure $
        cover 10 (shape == Just AssetSuccess) "asset success" $
            cover 30 (shape == Just Unchanged) "unchanged answer" $
                cover 5 (isAssetLine (caseLine c) && shape == Just Unchanged) "asset error answer" $
                    case divergence pre cur of
                        Right _ -> QC.property True
                        Left why -> counterexample (show (caseLine c) <> ": " <> why) False

{- | Flip each byte of the current answer that the earlier server
also wrote, one at a time, and require 'divergence' to reject each.
-}
flipsDetected :: UTCTime -> (Pair, ByteString) -> IO Int
flipsDetected at (pair, line) = do
    let c = Case pair (Readiness True (Just 20) (Just 9) (Just 11) Nothing at) line
    (pre, cur) <- askBoth c
    divergence pre cur `shouldSatisfy` either (const False) (const True)
    let comparable
            | isAssetSuccess pre = BS.length pre - 1
            | otherwise = BS.length cur
        positions = [BS.length cur - comparable .. BS.length cur - 1]
    forM_ positions $ \i ->
        either (const True) (const False) (divergence pre (flipByteAt i cur))
            `shouldBe` True
    pure (length positions)

flipByteAt :: Int -> ByteString -> ByteString
flipByteAt i bs =
    let (before, after) = BS.splitAt i bs
     in case BS.uncons after of
            Just (b, rest) -> before <> BS.cons (b `xor` 0x01) rest
            Nothing -> bs

-- * The two servers, over a seeded and an empty store

data Pair = Pair
    { pairLabel :: String
    , pairPre :: FilePath
    , pairCur :: FilePath
    , pairReady :: IORef Readiness
    , pairSeeded :: Bool
    }

instance Show Pair where
    show = pairLabel

withServerPairs :: ([Pair] -> IO a) -> IO a
withServerPairs action =
    withPair "seeded store" True $ \seeded ->
        withPair "empty store" False $ \empty ->
            action [seeded, empty]

withPair :: String -> Bool -> (Pair -> IO a) -> IO a
withPair label seeded action =
    withInMemoryIndexer $ \h -> do
        when seeded (seedFixture h)
        at <- getCurrentTime
        ref <- newIORef (Readiness False Nothing Nothing Nothing Nothing at)
        withSocketServer (\p -> Pre.runServer p h (preReady <$> readIORef ref)) $ \pre ->
            withSocketServer
                (\p -> Cur.runServer p h disclosure (curReady <$> readIORef ref))
                $ \cur -> action (Pair label pre cur ref seeded)
  where
    disclosure =
        Disclosure
            { dsNetworkMagic = 42
            , dsCoverage =
                Coverage
                    (FromPoint (SlotNo 3) (BlockHash (BS.replicate 32 3)))
                    FilteredAddresses
            , dsReadyThresholdSlots = 60
            , dsStaleAfterSeconds = 600
            }

askBoth :: Case -> IO (ByteString, ByteString)
askBoth c = do
    writeIORef (pairReady (casePair c)) (caseReadiness c)
    (,)
        <$> requestLine (pairPre (casePair c)) (caseLine c)
        <*> requestLine (pairCur (casePair c)) (caseLine c)

-- | A readiness sample, rendered into either server's own type.
data Readiness = Readiness
    { rdReady :: Bool
    , rdTip :: Maybe Word64
    , rdProcessed :: Maybe Word64
    , rdBehind :: Maybe Word64
    , rdDisconnect :: Maybe (Text, Int, Word64)
    , rdLastProgress :: UTCTime
    }
    deriving stock (Show)

upstreamOf :: Readiness -> UpstreamStatus
upstreamOf r = case rdDisconnect r of
    Nothing -> UpstreamConnected
    Just (reason, attempt, since) ->
        UpstreamDisconnected (DisconnectInfo reason attempt since)

preReady :: Readiness -> Pre.ReadyStatus
preReady r =
    Pre.ReadyStatus
        { Pre.rsReady = rdReady r
        , Pre.rsTipSlot = SlotNo <$> rdTip r
        , Pre.rsProcessedSlot = SlotNo <$> rdProcessed r
        , Pre.rsSlotsBehind = rdBehind r
        , Pre.rsUpstream = upstreamOf r
        }

curReady :: Readiness -> Cur.ReadyStatus
curReady r =
    Cur.ReadyStatus
        { Cur.rsReady = rdReady r
        , Cur.rsTipSlot = SlotNo <$> rdTip r
        , Cur.rsProcessedSlot = SlotNo <$> rdProcessed r
        , Cur.rsSlotsBehind = rdBehind r
        , Cur.rsUpstream = upstreamOf r
        , Cur.rsLastProgress = rdLastProgress r
        }

-- * Cases

data Case = Case
    { casePair :: Pair
    , caseReadiness :: Readiness
    , caseLine :: ByteString
    }
    deriving stock (Show)

genCase :: [Pair] -> Gen Case
genCase pairs = do
    pair <- elements pairs
    Case pair <$> genReadiness <*> elements (requestLines pair)

genReadiness :: Gen Readiness
genReadiness =
    Readiness
        <$> QC.arbitrary
        <*> genMaybe genSlot
        <*> genMaybe genSlot
        <*> genMaybe genSlot
        <*> frequency
            [ (3, pure Nothing)
            , (1, Just <$> ((,,) <$> elements ["bearer-closed", "probe"] <*> choose (0, 50) <*> genSlot))
            ]
        <*> genTime
  where
    genSlot = oneof [choose (0, 100_000), pure maxBound]
    genMaybe g = oneof [pure Nothing, Just <$> g]
    genTime = do
        offset <- choose (-100_000, 100_000 :: Integer)
        pure (addUTCTime (fromInteger offset) epoch)
    epoch = read "2026-10-01 12:00:00 UTC"

-- | One line of every request shape.
requestLines :: Pair -> [ByteString]
requestLines _ =
    [ assetLine assetPolicy "tok"
    , assetLine assetPolicy "none"
    , assetLine assetPolicy ""
    , assetLine (BS.replicate 27 0x11) "tok"
    , encodeLine
        [ "utxos_with_asset"
            .= Aeson.object
                [ "policy_id" .= hex assetPolicy
                , "asset_name" .= hex "tok"
                , "extra" .= True
                ]
        ]
    , encodeLine ["utxos_at" .= hex (addressBytes 0xA1)]
    , encodeLine ["utxos_at" .= hex (addressBytes 0xB0)]
    , encodeLine ["ready" .= Aeson.Null]
    , awaitLine (fixtureTxIn 1)
    , awaitLine missingTxIn
    , "not json"
    ]

{- | An @await@ line that never waits: a zero timeout answers at once
whether or not the store holds the TxIn. Every @await@ in this spec is
built here, so no request can block on a store that lacks its TxIn.
-}
awaitLine :: TxIn -> ByteString
awaitLine txIn =
    encodeLine ["await" .= wireTxIn txIn, "timeout_seconds" .= (0 :: Int)]

-- | The lines the byte-flip control runs, one per answer shape.
controlLines :: Pair -> [ByteString]
controlLines pair
    | pairSeeded pair =
        [ assetLine assetPolicy "tok"
        , assetLine assetPolicy "none"
        , assetLine (BS.replicate 27 0x11) "tok"
        , encodeLine ["ready" .= Aeson.Null]
        , encodeLine ["utxos_at" .= hex (addressBytes 0xA1)]
        ]
    | otherwise = [assetLine assetPolicy "tok"]

isAssetLine :: ByteString -> Bool
isAssetLine = BS.isInfixOf "utxos_with_asset"

-- * Fixture

assetPolicy :: ByteString
assetPolicy = BS.replicate 28 0x11

fixtureTxIn :: Word16 -> TxIn
fixtureTxIn = TxIn (BS.replicate 32 0x5A)

missingTxIn :: TxIn
missingTxIn = TxIn (BS.replicate 32 0x0F) 0

wireTxIn :: TxIn -> Text
wireTxIn (TxIn tid ix) = hex tid <> "#" <> showText ix
  where
    showText = Key.toText . Key.fromString . show

addressBytes :: Word8 -> ByteString
addressBytes = serialiseAddr . addressOf

addressOf :: Word8 -> Addr
addressOf b =
    Addr
        Testnet
        (KeyHashObj (KeyHash (UnsafeHash (SBS.toShort (BS.replicate 28 b)))))
        StakeRefNull

seedFixture :: IndexerHandle -> IO ()
seedFixture h = do
    applyAtSlot
        h
        (SlotNo 5)
        (BlockHash (BS.replicate 32 5))
        [ create 0 0xA1 []
        , create 1 0xA1 [(assetPolicy, "tok", 3), (assetPolicy, "", 1)]
        ]
    applyAtSlot
        h
        (SlotNo 9)
        (BlockHash (BS.replicate 32 9))
        [create 2 0xA2 [(assetPolicy, "tok", 4)]]
  where
    create ix a assets =
        UtxoCreate
            (fixtureTxIn ix)
            (Address (addressBytes a))
            (TxOut (serialize' (Ledger.eraProtVerLow @ConwayEra) (out a assets)))
    out a assets =
        mkBasicTxOut @ConwayEra
            (addressOf a)
            ( Mary.valueFromList
                (Coin 2_000_000)
                [ ( Mary.PolicyID (ScriptHash (UnsafeHash (SBS.toShort p)))
                  , Mary.AssetName (SBS.toShort n)
                  , q
                  )
                | (p, n, q) <- assets
                ]
            )
