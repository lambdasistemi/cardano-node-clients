{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.ServerStabilitySpec
Description : utxos_at, ready and await keep their bytes
License     : Apache-2.0

Adding @utxos_with_asset@ must not change a byte of what the existing
requests send or receive. The expected bytes are produced at run time
by the server as it shipped before the asset request:
"Cardano.Node.Client.UTxOIndexer.PreAssetServer" is that earlier
@Server@ source with only its module name changed. Both servers
listen on their own socket over one indexer and one readiness
snapshot and receive the same generated request line. Their answers
must be byte-identical, except for a line the earlier server rejected
as malformed that carries the new @utxos_with_asset@ key: that line
is the new request, and the current server must answer it with an
asset answer.
-}
module Cardano.Node.Client.UTxOIndexer.ServerStabilitySpec (spec) where

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
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    UtxoOp (..),
    withInMemoryIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.PreAssetServer qualified as Pre
import Cardano.Node.Client.UTxOIndexer.Server qualified as Cur
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Cardano.Node.Client.UTxOIndexer.WireClient (
    encodeLine,
    hex,
    requestLine,
    withSocketServer,
 )
import Control.Monad (forM_, unless)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (nubBy)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16, Word64, Word8)
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
    listOf,
    oneof,
    output,
    quickCheckWithResult,
    shuffle,
    stdArgs,
    sublistOf,
    vectorOf,
 )
import Test.QuickCheck qualified as QC

spec :: Spec
spec = describe "utxo-indexer socket: existing requests keep their bytes" $ do
    it "answers every generated request line as the pre-asset server does" $
        withServerPair $ \pair -> do
            result <-
                quickCheckWithResult
                    stdArgs{maxSuccess = 400, chatty = False}
                    (checkCoverage (forAll genCase (answersAlike pair)))
            unless (isSuccess result) (expectationFailure (output result))

    it "detects a change of any single byte in an existing endpoint's answer" $
        withServerPair $ \pair -> do
            checked <- sum <$> traverse (flipsDetected pair) controlCases
            checked `shouldSatisfy` (> 0)

{- | Send one case to both servers and compare. Coverage is counted
over what the pre-asset server answered, so every existing answer
shape is exercised, not only rejections.
-}
answersAlike :: Pair -> Case -> Property
answersAlike pair c = ioProperty $ do
    (pre, cur) <- askBoth pair c
    let shape = answerShape (pairMalformed pair) pre
        asset = carriesAssetKey (caseLine c)
    pure $
        cover 8 (shape == UtxosWithOutputs) "utxos_at with outputs" $
            cover 2 (shape == UtxosEmpty) "utxos_at without outputs" $
                cover 8 (shape == ReadyAnswer) "ready, upstream connected" $
                    cover 2 (shape == ReadyDisconnected) "ready, upstream disconnected" $
                        cover 5 (shape == AwaitObserved) "await observation" $
                            cover 3 (shape == AwaitTimeout) "await timeout" $
                                cover 10 (shape == Malformed) "rejected as malformed" $
                                    cover 2 (asset && shape /= Malformed) "asset key on a line answered by an existing endpoint" $
                                        cover 5 (asset && shape == Malformed) "asset key on a line the pre-asset server rejects" $
                                            case divergence (pairMalformed pair) (caseLine c) pre cur of
                                                Nothing -> QC.property True
                                                Just why -> counterexample why False

{- | 'Nothing' when the current answer is acceptable for the line:
identical bytes, or — for a line the earlier server rejected that
carries the asset key — an asset answer.
-}
divergence :: ByteString -> ByteString -> ByteString -> ByteString -> Maybe String
divergence malformed line pre cur
    | pre == cur = Nothing
    | pre == malformed && carriesAssetKey line =
        if isAssetAnswer cur
            then Nothing
            else Just ("asset request not answered as one: " <> show (line, cur))
    | otherwise =
        Just ("bytes differ for " <> show line <> ": pre " <> show pre <> ", now " <> show cur)

{- | Flip every byte of the current server's answer, one at a time,
and require 'divergence' to report each change. Returns the number
of flips checked.
-}
flipsDetected :: Pair -> Case -> IO Int
flipsDetected pair c = do
    (pre, cur) <- askBoth pair c
    divergence (pairMalformed pair) (caseLine c) pre cur `shouldBe` Nothing
    let positions = [0 .. BS.length cur - 1]
    forM_ positions $ \i ->
        divergence (pairMalformed pair) (caseLine c) pre (flipByteAt i cur)
            `shouldSatisfy` isJust
    pure (length positions)

flipByteAt :: Int -> ByteString -> ByteString
flipByteAt i bs =
    let (before, after) = BS.splitAt i bs
     in case BS.uncons after of
            Just (b, rest) -> before <> BS.cons (b `xor` 0x01) rest
            Nothing -> bs

-- | One request of each existing answer shape.
controlCases :: [Case]
controlCases =
    [ Case connected (encodeLine ["utxos_at" .= hex (addressBytes 0xA1)])
    , Case connected (encodeLine ["utxos_at" .= hex (BS.replicate 29 0x01)])
    , Case connected (encodeLine ["ready" .= Aeson.Null])
    , Case disconnected (encodeLine ["ready" .= Aeson.Null])
    , Case connected (encodeLine ["await" .= wireTxIn (fixtureTxIn 0)])
    , Case
        connected
        (encodeLine ["await" .= wireTxIn missingTxIn, "timeout_seconds" .= (0 :: Int)])
    , Case connected "not json"
    ]
  where
    connected = Readiness True (Just 20) (Just 12) (Just 8) Nothing
    disconnected =
        Readiness True (Just 20) (Just 12) (Just 8) (Just ("bearer-closed", 3, 4200))

-- * The two servers

data Pair = Pair
    { pairPre :: FilePath
    , pairCur :: FilePath
    , pairReady :: IORef Readiness
    , pairMalformed :: ByteString
    -- ^ The pre-asset server's answer to a line that is not JSON.
    }

withServerPair :: (Pair -> IO a) -> IO a
withServerPair action =
    withInMemoryIndexer $ \h -> do
        seedFixture h
        ref <- newIORef (Readiness False Nothing Nothing Nothing Nothing)
        withSocketServer (\p -> Pre.runServer p h (preReady <$> readIORef ref)) $ \pre ->
            withSocketServer (\p -> Cur.runServer p h (curReady <$> readIORef ref)) $ \cur -> do
                malformed <- requestLine pre "not json"
                action (Pair pre cur ref malformed)

askBoth :: Pair -> Case -> IO (ByteString, ByteString)
askBoth pair c = do
    writeIORef (pairReady pair) (caseReadiness c)
    (,)
        <$> requestLine (pairPre pair) (caseLine c)
        <*> requestLine (pairCur pair) (caseLine c)

-- | A readiness snapshot, rendered into either server's own type.
data Readiness = Readiness
    { rdReady :: Bool
    , rdTip :: Maybe Word64
    , rdProcessed :: Maybe Word64
    , rdBehind :: Maybe Word64
    , rdDisconnect :: Maybe (Text, Int, Word64)
    }
    deriving stock (Show)

upstreamOf :: Readiness -> UpstreamStatus
upstreamOf r = case rdDisconnect r of
    Nothing -> UpstreamConnected
    Just (reason, attempt, since) -> UpstreamDisconnected (DisconnectInfo reason attempt since)

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
        }

-- * Fixture: two blocks of ledger-built outputs, one holding an asset

addressBytes :: Word8 -> ByteString
addressBytes = serialiseAddr . addressOf

addressOf :: Word8 -> Addr
addressOf b =
    Addr
        Testnet
        (KeyHashObj (KeyHash (UnsafeHash (SBS.toShort (BS.replicate 28 b)))))
        StakeRefNull

fixtureTxIn :: Word16 -> TxIn
fixtureTxIn = TxIn (BS.replicate 32 0x5A)

-- | A well-formed TxIn the fixture never creates.
missingTxIn :: TxIn
missingTxIn = TxIn (BS.replicate 32 0x0F) 0

assetPolicy :: ByteString
assetPolicy = BS.replicate 28 0x11

seedFixture :: IndexerHandle -> IO ()
seedFixture h = do
    applyAtSlot
        h
        (SlotNo 5)
        (BlockHash (BS.replicate 32 5))
        [ create 0 0xA1 []
        , create 1 0xA1 [(assetPolicy, "tok", 3)]
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

-- * Generated cases

data Case = Case
    { caseReadiness :: Readiness
    , caseLine :: ByteString
    }
    deriving stock (Show)

genCase :: Gen Case
genCase = Case <$> genReadiness <*> genLine

genReadiness :: Gen Readiness
genReadiness =
    Readiness
        <$> QC.arbitrary
        <*> genMaybe genSlot
        <*> genMaybe genSlot
        <*> genMaybe genSlot
        <*> frequency
            [ (3, pure Nothing)
            , (1, Just <$> ((,,) <$> genText <*> choose (0, 50) <*> genSlot))
            ]
  where
    genSlot = oneof [choose (0, 100_000), pure maxBound]

{- | A request line: one existing request, an asset request, a mix of
keys on one object, a JSON value that is not an object, or text that
is not JSON. No line ever waits: an @await@ on a TxIn the fixture
never created always carries a zero or negative timeout, or a timeout
that fails to parse.
-}
genLine :: Gen ByteString
genLine =
    frequency
        [ (4, encodeLine <$> genUtxosAt)
        , (3, encodeLine <$> genReady)
        , (6, encodeLine <$> genAwait)
        , (2, encodeLine <$> genAsset)
        , (5, encodeLine <$> genMixed)
        , (1, BSL.toStrict . Aeson.encode <$> genNonObject)
        , (2, genNotJson)
        ]

genUtxosAt :: Gen [(Key.Key, Aeson.Value)]
genUtxosAt = do
    v <-
        frequency
            [ (5, Aeson.String . hex . addressBytes <$> elements [0xA1, 0xA2])
            , (1, Aeson.String . Text.toUpper . hex . addressBytes <$> elements [0xA1, 0xA2])
            , (2, Aeson.String . hex <$> genBytes 0 40)
            , (1, Aeson.String <$> elements ["abc", "zz", "0x00"])
            , (1, genScalar)
            ]
    pure [("utxos_at", v)]

genReady :: Gen [(Key.Key, Aeson.Value)]
genReady = do
    v <- oneof [pure Aeson.Null, genScalar, pure (Aeson.object []), pure (Aeson.toJSON [1 :: Int])]
    pure [("ready", v)]

genAwait :: Gen [(Key.Key, Aeson.Value)]
genAwait =
    frequency
        [ (4, observed)
        , (3, unobserved)
        , (2, badTxIn)
        , (1, (\v -> [("await", v)]) <$> genScalar)
        ]
  where
    observed = do
        t <- elements (map fixtureTxIn [0, 1, 2])
        upper <- QC.arbitrary
        let wire = if upper then Text.toUpper (wireTxIn t) else wireTxIn t
        timeout <- genMaybe (elements [Aeson.Number 0, Aeson.Number 5, Aeson.Number (-1), Aeson.String "1", Aeson.Number 1.5, Aeson.Null])
        pure (("await", Aeson.String wire) : maybe [] (\v -> [("timeout_seconds", v)]) timeout)
    unobserved = do
        tid <- BS.pack <$> vectorOf 32 QC.arbitrary
        timeout <- elements [Aeson.Number 0, Aeson.Number (-1), Aeson.String "1"]
        pure
            [ ("await", Aeson.String (wireTxIn (TxIn tid 0)))
            , ("timeout_seconds", timeout)
            ]
    badTxIn = do
        let tid = hex (BS.replicate 32 0x5A)
        v <-
            elements
                [ tid
                , tid <> "#"
                , "#0"
                , hex (BS.replicate 31 0x5A) <> "#0"
                , tid <> "#65536"
                , tid <> "#-1"
                , tid <> "#x"
                , Text.replicate 64 "z" <> "#0"
                ]
        pure [("await", Aeson.String v)]

genAsset :: Gen [(Key.Key, Aeson.Value)]
genAsset = do
    v <-
        oneof
            [ assetObject <$> elements [hex assetPolicy, hex (BS.replicate 27 0x11), "zz"] <*> elements [hex "tok", "", "746f6"]
            , genScalar
            , pure (Aeson.object [])
            ]
    pure [("utxos_with_asset", v)]
  where
    assetObject p n = Aeson.object ["policy_id" .= (p :: Text), "asset_name" .= (n :: Text)]

{- | Several request keys on one object. 'nubBy' keeps the first
generator's value for a repeated key, so an @await@ entry keeps the
timeout generated with it.
-}
genMixed :: Gen [(Key.Key, Aeson.Value)]
genMixed = do
    parts <- sublistOf [genUtxosAt, genReady, genAwait, genAsset, genJunk]
    ordered <- shuffle parts
    pairs <- concat <$> sequence ordered
    pure (nubBy (\a b -> fst a == fst b) pairs)
  where
    genJunk = do
        k <- elements ["x", "Ready", "UTXOS_AT", "utxos", "asset", "policy_id", ""]
        v <- genScalar
        pure [(k, v)]

genNonObject :: Gen Aeson.Value
genNonObject =
    oneof
        [ genScalar
        , pure (Aeson.toJSON [Aeson.object ["ready" .= Aeson.Null]])
        , pure (Aeson.String "utxos_with_asset")
        ]

genNotJson :: Gen ByteString
genNotJson =
    oneof
        [ elements
            [ ""
            , "   "
            , "not json"
            , "{"
            , "{\"ready\":null"
            , "{\"ready\":null}}"
            , "{\"ready\":null} trailing"
            , "{\"utxos_with_asset\":"
            ]
        , BS8.pack <$> listOf (elements (['a' .. 'z'] <> "{}[]\":, "))
        ]

genScalar :: Gen Aeson.Value
genScalar =
    oneof
        [ pure Aeson.Null
        , Aeson.Bool <$> QC.arbitrary
        , Aeson.Number . fromInteger <$> choose (-3, 70_000)
        , Aeson.String <$> genText
        ]

genText :: Gen Text
genText = Text.pack <$> listOf (elements (['a' .. 'f'] <> "\"\\ é#0"))

genMaybe :: Gen a -> Gen (Maybe a)
genMaybe g = oneof [pure Nothing, Just <$> g]

genBytes :: Int -> Int -> Gen ByteString
genBytes lo hi = do
    n <- choose (lo, hi)
    BS.pack <$> vectorOf n QC.arbitrary

-- * Reading answers

data Shape
    = UtxosWithOutputs
    | UtxosEmpty
    | ReadyAnswer
    | ReadyDisconnected
    | AwaitObserved
    | AwaitTimeout
    | Malformed
    | Other
    deriving stock (Eq, Show)

answerShape :: ByteString -> ByteString -> Shape
answerShape malformed resp
    | resp == malformed = Malformed
    | otherwise = case Aeson.decodeStrict' resp of
        Just (Aeson.Object o)
            | Just (Aeson.Array xs) <- KM.lookup "utxos" o ->
                if null xs then UtxosEmpty else UtxosWithOutputs
            | KM.member "upstream" o -> ReadyDisconnected
            | KM.member "ready" o -> ReadyAnswer
            | KM.member "slot" o -> AwaitObserved
            | KM.member "timeout" o -> AwaitTimeout
        _ -> Other

carriesAssetKey :: ByteString -> Bool
carriesAssetKey line = case Aeson.decodeStrict' line of
    Just (Aeson.Object o) -> KM.member "utxos_with_asset" o
    _ -> False

-- | A success answer or one of the two asset error families.
isAssetAnswer :: ByteString -> Bool
isAssetAnswer resp = case Aeson.decodeStrict' resp of
    Just (Aeson.Object o) ->
        (KM.member "point" o && KM.member "utxos" o)
            || KM.lookup "error" o
                `elem` map Just ["invalid_asset_query", "asset_index_unavailable"]
    _ -> False

-- * Small helpers

wireTxIn :: TxIn -> Text
wireTxIn (TxIn tid ix) = hex tid <> "#" <> Text.pack (show ix)
