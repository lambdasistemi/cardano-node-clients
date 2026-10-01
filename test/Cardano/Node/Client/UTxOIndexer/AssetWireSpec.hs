{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.AssetWireSpec
Description : utxos_with_asset over the indexer's NDJSON socket
License     : Apache-2.0

Speaks the real Unix socket of 'runServer' over indexers seeded with
ledger-built Conway outputs and checks the v1 wire contract of the
@utxos_with_asset@ request: the success answer, datum honesty, asset
identity (empty, non-UTF-8 and maximal names, one name under two
policies), malformed requests, and the explicit unavailability
answers.

Expected values come from producers at run time, never from typed
constants: the holder set and the quantities from the same daemon's
@utxos_at@ decoded by the ledger, creation points from the same
daemon's @await@, the point from the indexer's rollback history, and
datum views from 'decodeTxOutView' and from the ledger's decoding of
the bytes the daemon returned.
-}
module Cardano.Node.Client.UTxOIndexer.AssetWireSpec (spec) where

import Cardano.Crypto.Hash.Class (Hash (UnsafeHash), hashToBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Binary (
    DecoderError,
    decCBOR,
    decodeFullDecoder,
    serialize',
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Credential (
    Credential (KeyHashObj),
    StakeReference (StakeRefNull),
 )
import Cardano.Ledger.Hashes (
    ScriptHash (..),
    extractHash,
    originalBytes,
    unsafeMakeSafeHash,
 )
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value qualified as Mary
import Cardano.Ledger.Plutus.Data (Datum (..), makeBinaryData)
import Cardano.Node.Client.N2C.Reconnect (UpstreamStatus (..))
import Cardano.Node.Client.UTxOIndexer.Columns (
    Cols (..),
    addressIndexCodecs,
    observationColCodecs,
    rollbackCodecs,
    txInColCodecs,
 )
import Cardano.Node.Client.UTxOIndexer.Indexer (
    IndexerHandle (..),
    UtxoOp (..),
    withInMemoryIndexer,
    withInMemoryIndexerRunner,
    withRocksDBIndexer,
 )
import Cardano.Node.Client.UTxOIndexer.Server (
    ReadyStatus (..),
    runServer,
 )
import Cardano.Node.Client.UTxOIndexer.TxOutView qualified as View
import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey (..),
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Cardano.Node.Client.UTxOIndexer.WireClient (
    Answer (..),
    Match (..),
    askAsset,
    assetLine,
    assetLineText,
    awaitPoint,
    decoded,
    encodeLine,
    expectAnswer,
    hex,
    hexBytes,
    holderOf,
    objectWithKeys,
    requestLine,
    successAnswer,
    textField,
    txInOrder,
    utxosAt,
    withSocketServer,
 )
import ChainFollower.Rollbacks.Types (RollbackPoint (..))
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Default.Class (def)
import Data.List (nub, sort, sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64, Word8)
import Database.KV.Database (Codecs, mkColumns)
import Database.KV.RocksDB (mkRocksDBDatabase)
import Database.KV.Transaction (
    DMap,
    DSum ((:=>)),
    RunTransaction (..),
    delete,
    fromList,
    insert,
    newRunTransaction,
 )
import Database.RocksDB (Config (..), columnFamilies, withDBCF)
import Lens.Micro ((&), (.~), (^.))
import System.IO.Temp (withSystemTempDirectory)
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
    chooseInt,
    counterexample,
    elements,
    forAll,
    ioProperty,
    isSuccess,
    oneof,
    output,
    quickCheckWithResult,
    stdArgs,
    suchThat,
    vectorOf,
 )
import Test.QuickCheck qualified as QC

spec :: Spec
spec = describe "utxo-indexer socket: utxos_with_asset" $ do
    describe "success answer" $ do
        it "lists every live holder in ascending TxIn order with its ledger quantity" $
            withFixture $ \_ sock -> do
                live <- liveOutputs sock
                forM_ queriedAssets $ \asset -> do
                    answer <- askAsset sock asset
                    map holderOf (ansMatches answer)
                        `shouldBe` expectedHolders live asset
                -- the fixture's cardinality, not an expected value
                length (expectedHolders live (policyA, nameTok))
                    `shouldSatisfy` (> 1)

        it "renders quantities beyond 2^53 as exact decimal strings" $
            withFixture $ \_ sock -> do
                answer <- askAsset sock (policyA, nameTok)
                quantities <- forM (ansMatches answer) $ \m -> do
                    raw <- hexBytes (mTxOut m)
                    let q = ledgerQuantity raw (policyA, nameTok)
                    mQuantity m `shouldBe` Text.pack (show q)
                    pure q
                quantities `shouldSatisfy` any (> 2 ^ (53 :: Int))

        it "carries the newest applied block as its point" $
            withFixture $ \h sock -> do
                expected <- newestPoint h
                forM_ queriedAssets $ \asset -> do
                    answer <- askAsset sock asset
                    ansPoint answer `shouldBe` expected
                    forM_ (ansMatches answer) $ \m ->
                        fst (mCreated m) `shouldSatisfy` (<= fst expected)

        it "reports each holder's creation point as await does" $
            withFixture $ \_ sock -> do
                createds <- forM [(policyA, nameTok), (policyB, nameTok)] $ \asset -> do
                    answer <- askAsset sock asset
                    forM (ansMatches answer) $ \m -> do
                        observed <- awaitPoint sock (mTxIn m) 5
                        mCreated m `shouldBe` observed
                        pure (mCreated m)
                length (nub (concat createds)) `shouldSatisfy` (> 1)

        it "returns txout bytes identical to utxos_at for the same TxIn" $
            withFixture $ \_ sock -> do
                live <- liveOutputs sock
                forM_ queriedAssets $ \asset -> do
                    answer <- askAsset sock asset
                    forM_ (ansMatches answer) $ \m -> do
                        raw <- hexBytes (mTxOut m)
                        Just raw `shouldBe` lookup (mTxIn m) live

        it "writes lower-case hex in every hex field" $
            withFixture $ \_ sock ->
                forM_ queriedAssets $ \asset -> do
                    answer <- askAsset sock asset
                    let fields =
                            snd (ansPoint answer)
                                : concat
                                    [ [mTxIn m, mTxOut m, snd (mCreated m)]
                                        <> datumHexFields (mDatum m)
                                    | m <- ansMatches answer
                                    ]
                    forM_ fields $ \t -> t `shouldBe` Text.toLower t

        it "answers alongside an ada-only output of 2^32 lovelace or more" $
            withFixture $ \_ sock -> do
                live <- liveOutputs sock
                [() | (_, raw) <- live, ledgerCoin raw >= 2 ^ (32 :: Int)]
                    `shouldSatisfy` (not . null)
                answer <- askAsset sock (policyA, nameTok)
                ansMatches answer `shouldSatisfy` (not . null)

    describe "datum" $ do
        it "equals the TxOutView and the ledger's decoding of the returned bytes" $
            withFixture $ \_ sock -> do
                kinds <- forM queriedAssets $ \asset -> do
                    answer <- askAsset sock asset
                    forM (ansMatches answer) $ \m -> do
                        raw <- hexBytes (mTxOut m)
                        view <-
                            either (fail . show) pure $
                                View.decodeTxOutView (TxOut raw)
                        mDatum m `shouldBe` renderDatum (View.tovDatum view)
                        mDatum m `shouldBe` renderDatum (ledgerDatum raw)
                        pure (KM.lookup "kind" (mDatum m))
                sort (nub (concat kinds))
                    `shouldBe` map (Just . Aeson.String) ["hash", "inline", "none"]

        it "carries inline datum bytes as a byte slice of txout" $
            withFixture $ \_ sock -> do
                answer <- askAsset sock (policyA, nameTok)
                inlines <- fmap concat $ forM (ansMatches answer) $ \m ->
                    case KM.lookup "cbor" (mDatum m) of
                        Just (Aeson.String cbor) -> do
                            datumBytes <- hexBytes cbor
                            raw <- hexBytes (mTxOut m)
                            datumBytes `shouldSatisfy` (`BS.isInfixOf` raw)
                            pure [datumBytes]
                        _ -> pure []
                inlines `shouldSatisfy` (not . null)

        it "reports a hash-only datum as kind hash without cbor" $
            withFixture $ \_ sock -> do
                answer <- askAsset sock (policyB, nameTok)
                hashes <- fmap concat $ forM (ansMatches answer) $ \m -> do
                    raw <- hexBytes (mTxOut m)
                    case ledgerDatum raw of
                        View.DatumHash h -> do
                            mDatum m
                                `shouldBe` KM.fromList
                                    [("kind", "hash"), ("hash", Aeson.String (hex h))]
                            pure [h]
                        _ -> pure []
                hashes `shouldSatisfy` (not . null)

        it "answers inconsistent instead of a datum when stored bytes do not decode" $
            withInMemoryIndexerRunner $ \h runner -> do
                seedFixture h
                let (txIn, addr, out) = corruptedHolder
                    raw = storedBytes out
                runTransaction runner $
                    insert
                        AddressIndex
                        (AddrKey (indexerAddress addr) txIn)
                        (TxOut (BS.take (BS.length raw - 1) raw))
                withServer h $ \sock -> do
                    resp <- requestLine sock (assetLine policyA nameTok)
                    expectUnavailable resp "inconsistent"

    describe "asset identity" $ do
        it "answers one asset name per policy" $
            withFixture $ \_ sock -> do
                live <- liveOutputs sock
                a <- askAsset sock (policyA, nameTok)
                b <- askAsset sock (policyB, nameTok)
                map holderOf (ansMatches a)
                    `shouldBe` expectedHolders live (policyA, nameTok)
                map holderOf (ansMatches b)
                    `shouldBe` expectedHolders live (policyB, nameTok)
                let shared =
                        [ (qa, qb)
                        | (ta, qa) <- map holderOf (ansMatches a)
                        , (tb, qb) <- map holderOf (ansMatches b)
                        , ta == tb
                        ]
                shared `shouldSatisfy` any (uncurry (/=))
                length (ansMatches b) `shouldSatisfy` (> 1)

        forM_
            [ ("the empty asset name", nameEmpty)
            , ("a non-UTF-8 asset name", nameNonUtf8)
            , ("a 32-byte asset name", nameMax)
            ]
            $ \(label, name) ->
                it ("answers " <> label) $
                    withFixture $ \_ sock -> do
                        live <- liveOutputs sock
                        answer <- askAsset sock (policyA, name)
                        map holderOf (ansMatches answer)
                            `shouldBe` expectedHolders live (policyA, name)
                        ansMatches answer `shouldSatisfy` (not . null)

        it "reads hex input case-insensitively" $
            withFixture $ \_ sock -> do
                lower <- requestLine sock (assetLine policyA nameTok)
                upper <-
                    requestLine sock $
                        assetLineText
                            (Text.toUpper (hex policyA))
                            (Text.toUpper (hex nameTok))
                mixed <-
                    requestLine sock $
                        assetLineText (mixCase (hex policyA)) (mixCase (hex nameTok))
                _ <- expectAnswer lower
                upper `shouldBe` lower
                mixed `shouldBe` lower

        it "accepts every asset name of 0 to 32 bytes" $
            withFixture $ \_ sock ->
                quickCheckIO 200 $
                    forAll (genBytes 0 32) $ \name -> ioProperty $ do
                        resp <- requestLine sock (assetLine policyA name)
                        pure $ case successAnswer resp of
                            Right _ -> QC.property True
                            Left why -> counterexample (why <> "; answer was " <> show resp) False

    describe "invalid_asset_query" $ do
        forM_ malformedRequests $ \(label, line) ->
            it ("rejects " <> label) $
                withFixture $ \_ sock -> do
                    resp <- requestLine sock line
                    detail <- expectInvalid resp
                    detail `shouldSatisfy` (not . Text.null)

        it "names an unknown key inside the request object" $
            withFixture $ \_ sock -> do
                resp <-
                    requestLine sock $
                        encodeLine
                            [ "utxos_with_asset"
                                .= Aeson.object
                                    [ "policy_id" .= hex policyA
                                    , "asset_name" .= hex nameTok
                                    , "start_slot" .= (5 :: Int)
                                    ]
                            ]
                detail <- expectInvalid resp
                detail `shouldSatisfy` Text.isInfixOf "start_slot"

        it "rejects every policy id that is not 28 bytes" $
            withFixture $ \_ sock ->
                quickCheckIO 200 $
                    forAll (genBytes 0 64 `suchThat` ((/= 28) . BS.length)) $
                        \policy -> ioProperty $ do
                            resp <- requestLine sock (assetLine policy nameTok)
                            pure (invalidProperty resp)

        it "rejects every asset name longer than 32 bytes" $
            withFixture $ \_ sock ->
                quickCheckIO 200 $
                    forAll (genBytes 33 80) $ \name -> ioProperty $ do
                        resp <- requestLine sock (assetLine policyA name)
                        pure (invalidProperty resp)

    describe "asset_index_unavailable" $ do
        it "answers no_indexed_point on a store with no applied block" $
            withInMemoryIndexer $ \h -> withServer h $ \sock -> do
                resp <- requestLine sock (assetLine policyA nameTok)
                expectUnavailable resp "no_indexed_point"

        it "answers absent on a store created before the asset index" $
            withSystemTempDirectory "asset-wire-prechange" $ \tmp -> do
                let path = tmp <> "/db"
                seedPreChangeStore path
                withRocksDBIndexer path $ \h -> withServer h $ \sock -> do
                    resp <- requestLine sock (assetLine policyA nameTok)
                    expectUnavailable resp "absent"

        it "answers absent once the asset index lost completeness" $
            withInMemoryIndexer $ \h -> do
                seedFixture h
                applyAtSlot
                    h
                    (SlotNo 20)
                    (blockHashAt 20)
                    [ UtxoCreate
                        (TxIn (txId 0x66) 0)
                        (indexerAddress (addressOf 0xA4))
                        (TxOut (BS.pack [0x82, 0x41]))
                    ]
                withServer h $ \sock -> do
                    resp <- requestLine sock (assetLine policyA nameTok)
                    expectUnavailable resp "absent"

        it "answers inconsistent when an asset row has no live output" $
            withInMemoryIndexerRunner $ \h runner -> do
                seedFixture h
                let (txIn, _, _) = corruptedHolder
                runTransaction runner $ delete TxInCol txIn
                withServer h $ \sock -> do
                    resp <- requestLine sock (assetLine policyA nameTok)
                    expectUnavailable resp "inconsistent"

-- * Fixture

policyA, policyB, policyC :: ByteString
policyA = BS.replicate 28 0x11
policyB = BS.replicate 28 0x22
policyC = BS.replicate 28 0x33

nameTok, nameTo, nameEmpty, nameNonUtf8, nameMax :: ByteString
nameTok = "tok"
nameTo = "to"
nameEmpty = ""
nameNonUtf8 = BS.pack [0xFF, 0xFE, 0x80]
nameMax = BS.replicate 32 0xEE

{- | Every asset the success checks query: held ones, a strict prefix
of a held name, an unheld name and an unknown policy.
-}
queriedAssets :: [(ByteString, ByteString)]
queriedAssets =
    [ (policyA, nameTok)
    , (policyA, nameEmpty)
    , (policyA, nameTo)
    , (policyA, nameNonUtf8)
    , (policyA, nameMax)
    , (policyB, nameTok)
    , (policyA, "absent")
    , (policyC, nameTok)
    ]

{- | A Shelley enterprise testnet address whose payment key hash is
28 copies of the given byte.
-}
addressOf :: Word8 -> Addr
addressOf b =
    Addr
        Testnet
        (KeyHashObj (KeyHash (UnsafeHash (SBS.toShort (BS.replicate 28 b)))))
        StakeRefNull

-- | The address bytes the indexer keys outputs under.
indexerAddress :: Addr -> Address
indexerAddress = Address . serialiseAddr

fixtureAddresses :: [Addr]
fixtureAddresses = map addressOf [0xA1, 0xA2, 0xA3]

data DatumChoice
    = NoDatumC
    | HashDatumC ByteString
    | InlineDatumC ByteString

-- | A Conway output built by the ledger.
ledgerOut ::
    Addr ->
    [(ByteString, ByteString, Integer)] ->
    DatumChoice ->
    Ledger.TxOut ConwayEra
ledgerOut addr assets datum = withDatum (mkBasicTxOut addr value)
  where
    value =
        Mary.valueFromList
            (Coin 2_000_000)
            [ (ledgerPolicy p, Mary.AssetName (SBS.toShort n), q)
            | (p, n, q) <- assets
            ]
    withDatum o = case datum of
        NoDatumC -> o
        HashDatumC h ->
            o
                & datumTxOutL
                    .~ DatumHash (unsafeMakeSafeHash (UnsafeHash (SBS.toShort h)))
        InlineDatumC raw ->
            o
                & datumTxOutL
                    .~ Datum (either error id (makeBinaryData (SBS.toShort raw)))

ledgerPolicy :: ByteString -> Mary.PolicyID
ledgerPolicy p = Mary.PolicyID (ScriptHash (UnsafeHash (SBS.toShort p)))

storedBytes :: Ledger.TxOut ConwayEra -> ByteString
storedBytes = serialize' (Ledger.eraProtVerLow @ConwayEra)

txId :: Word8 -> ByteString
txId = BS.replicate 32

{- | Three blocks. Transaction ids descend while slots ascend, and one
transaction has outputs @#2@ and @#10@, so ascending 'TxIn' order is
neither creation order nor text order. The first block also creates
an ada-only neighbour of 5,000 ada, whose coin needs the eight-byte
CBOR argument. The third block spends the first holder.
-}
fixtureBlocks :: [(Word64, [(TxIn, Addr, Maybe (Ledger.TxOut ConwayEra))])]
fixtureBlocks =
    [
        ( 5
        ,
            [ create 0x55 0 0xA1 [(policyA, nameTok, 7), (policyA, nameEmpty, 3)] NoDatumC
            , create
                0x55
                1
                0xA2
                [ (policyA, nameTok, toInteger (maxBound :: Word64))
                , (policyA, nameNonUtf8, 2)
                ]
                (InlineDatumC (BS.pack [0x18, 0x2A]))
            ,
                ( TxIn (txId 0x55) 2
                , addressOf 0xA1
                , Just
                    ( mkBasicTxOut
                        (addressOf 0xA1)
                        (Mary.valueFromList (Coin 5_000_000_000) [])
                    )
                )
            ]
        )
    ,
        ( 9
        ,
            [ create
                0x44
                0
                0xA1
                [ (policyA, nameTok, 2 ^ (53 :: Int) + 1)
                , (policyB, nameTok, 4)
                , (policyA, nameEmpty, 1)
                ]
                (HashDatumC (BS.replicate 32 0xAB))
            , create
                0x44
                1
                0xA2
                [ (policyB, nameTok, 5)
                , (policyA, nameTo, 1)
                , (policyA, nameNonUtf8, 8)
                , (policyA, nameMax, 9)
                ]
                NoDatumC
            ]
        )
    ,
        ( 12
        ,
            [ (TxIn (txId 0x55) 0, addressOf 0xA1, Nothing)
            , create 0x33 0 0xA3 [] NoDatumC
            , create 0x33 2 0xA3 [(policyA, nameTok, 11), (policyA, nameEmpty, 6)] NoDatumC
            , create 0x33 10 0xA3 [(policyA, nameTok, 1)] NoDatumC
            ]
        )
    ]
  where
    create t ix a assets datum =
        ( TxIn (txId t) ix
        , addressOf a
        , Just (ledgerOut (addressOf a) assets datum)
        )

-- | The holder whose stored bytes the corruption tests break.
corruptedHolder :: (TxIn, Addr, Ledger.TxOut ConwayEra)
corruptedHolder =
    case [ (t, a, o)
         | (_, ops) <- fixtureBlocks
         , (t, a, Just o) <- ops
         , t == TxIn (txId 0x33) 2
         ] of
        holder : _ -> holder
        [] -> error "the fixture lost its corrupted holder"

seedFixture :: IndexerHandle -> IO ()
seedFixture h =
    forM_ fixtureBlocks $ \(slot, ops) ->
        applyAtSlot h (SlotNo slot) (blockHashAt slot) (map toOp ops)
  where
    toOp (t, a, Just o) = UtxoCreate t (indexerAddress a) (TxOut (storedBytes o))
    toOp (t, _, Nothing) = UtxoSpend t

blockHashAt :: Word64 -> BlockHash
blockHashAt slot = BlockHash (BS.replicate 32 (fromIntegral slot))

-- * Server harness

readyFixed :: ReadyStatus
readyFixed =
    ReadyStatus
        { rsReady = True
        , rsTipSlot = Just (SlotNo 20)
        , rsProcessedSlot = Just (SlotNo 12)
        , rsSlotsBehind = Just 8
        , rsUpstream = UpstreamConnected
        }

withServer :: IndexerHandle -> (FilePath -> IO a) -> IO a
withServer h =
    withSocketServer (\path -> runServer path h (pure readyFixed))

-- | A seeded in-memory indexer with the server on its socket.
withFixture :: (IndexerHandle -> FilePath -> IO a) -> IO a
withFixture action =
    withInMemoryIndexer $ \h -> do
        seedFixture h
        withServer h (action h)

{- | A RocksDB directory with only the four column families that
existed before the asset index, holding one live output and one
applied block.
-}
seedPreChangeStore :: FilePath -> IO ()
seedPreChangeStore path =
    withDBCF path def{createIfMissing = True} families $ \rdb -> do
        runner <-
            newRunTransaction
                (mkRocksDBDatabase rdb (mkColumns (columnFamilies rdb) codecs))
        let txIn = TxIn (txId 0x77) 0
            addr = indexerAddress (addressOf 0xA1)
            out = ledgerOut (addressOf 0xA1) [(policyA, nameTok, 5)] NoDatumC
        runTransaction runner $ do
            insert TxInCol txIn addr
            insert AddressIndex (AddrKey addr txIn) (TxOut (storedBytes out))
            insert ObservationCol txIn (SlotNo 7, blockHashAt 7)
            insert
                RollbackCol
                (SlotNo 7)
                RollbackPoint{rpInverses = [[]], rpMeta = Just (blockHashAt 7)}
  where
    families =
        [ ("utxo-indexer.txin", def)
        , ("utxo-indexer.address", def)
        , ("utxo-indexer.observation", def)
        , ("utxo-indexer.rollback", def)
        ]
    codecs :: DMap Cols Codecs
    codecs =
        fromList
            [ TxInCol :=> txInColCodecs
            , AddressIndex :=> addressIndexCodecs
            , ObservationCol :=> observationColCodecs
            , RollbackCol :=> rollbackCodecs
            ]

-- * Producers of expected values

-- | Every live output at the fixture addresses, as @utxos_at@ lists it.
liveOutputs :: FilePath -> IO [(Text, ByteString)]
liveOutputs sock =
    concat <$> traverse (utxosAt sock . serialiseAddr) fixtureAddresses

{- | The holders of one asset among the live outputs, with the
quantity the ledger reads from their bytes, in ascending 'TxIn'
order.
-}
expectedHolders :: [(Text, ByteString)] -> (ByteString, ByteString) -> [(Text, Text)]
expectedHolders live asset =
    [ (t, Text.pack (show q))
    | (t, raw) <- sortOn (txInOrder . fst) live
    , let q = ledgerQuantity raw asset
    , q > 0
    ]

ledgerDecode :: ByteString -> Ledger.TxOut ConwayEra
ledgerDecode raw =
    case decodeFullDecoder
            (Ledger.eraProtVerLow @ConwayEra)
            "txout"
            decCBOR
            (BSL.fromStrict raw) ::
            Either DecoderError (Ledger.TxOut ConwayEra) of
        Left e -> error (show e)
        Right o -> o

-- | The lovelace the ledger reads from stored bytes.
ledgerCoin :: ByteString -> Integer
ledgerCoin raw = unCoin (ledgerDecode raw ^. Ledger.coinTxOutL)

-- | The quantity of one asset the ledger reads from stored bytes.
ledgerQuantity :: ByteString -> (ByteString, ByteString) -> Integer
ledgerQuantity raw (policy, name) =
    sum
        [ q
        | (Mary.PolicyID (ScriptHash (UnsafeHash p)), Mary.AssetName n, q) <-
            Mary.flattenMultiAsset multiAsset
        , SBS.fromShort p == policy
        , SBS.fromShort n == name
        ]
  where
    Mary.MaryValue _ multiAsset = ledgerDecode raw ^. Ledger.valueTxOutL

-- | The datum view the ledger reads from stored bytes.
ledgerDatum :: ByteString -> View.DatumView
ledgerDatum raw = case ledgerDecode raw ^. datumTxOutL of
    NoDatum -> View.NoDatum
    DatumHash h -> View.DatumHash (hashToBytes (extractHash h))
    Datum d -> View.InlineDatum (originalBytes d)

-- | The newest applied block, from the indexer's rollback history.
newestPoint :: IndexerHandle -> IO (Integer, Text)
newestPoint h = do
    history <- getRollbackHistory h
    case [ (toInteger s, hex bh)
         | (SlotNo s, RollbackPoint{rpMeta = Just (BlockHash bh)}) <-
            reverse history
         ] of
        p : _ -> pure p
        [] -> fail "the fixture applied no block"

-- * Reading the answers

-- | The wire rendering of a datum view (spec, wire schema v1).
renderDatum :: View.DatumView -> KM.KeyMap Aeson.Value
renderDatum = \case
    View.NoDatum -> KM.fromList [("kind", "none")]
    View.DatumHash h ->
        KM.fromList [("kind", "hash"), ("hash", Aeson.String (hex h))]
    View.InlineDatum b ->
        KM.fromList [("kind", "inline"), ("cbor", Aeson.String (hex b))]

datumHexFields :: KM.KeyMap Aeson.Value -> [Text]
datumHexFields d =
    [t | k <- ["hash", "cbor"], Just (Aeson.String t) <- [KM.lookup k d]]

-- | Read an @invalid_asset_query@ answer; returns its detail.
expectInvalid :: ByteString -> IO Text
expectInvalid resp =
    either (\why -> fail (why <> "; answer was " <> show resp)) pure $ do
        o <- objectWithKeys ["detail", "error"] =<< decoded resp
        code <- textField "error" o
        unless (code == "invalid_asset_query") $
            Left ("error code " <> show code)
        textField "detail" o

invalidProperty :: ByteString -> Property
invalidProperty resp =
    case objectWithKeys ["detail", "error"] =<< decoded resp of
        Right o
            | KM.lookup "error" o == Just "invalid_asset_query" ->
                QC.property True
        _ -> counterexample ("answer was " <> show resp) False

-- | Require an @asset_index_unavailable@ answer with the given reason.
expectUnavailable :: ByteString -> Text -> IO ()
expectUnavailable resp reason =
    either (\why -> expectationFailure (why <> "; answer was " <> show resp)) pure $ do
        o <- objectWithKeys ["error", "reason"] =<< decoded resp
        code <- textField "error" o
        actual <- textField "reason" o
        when (code /= "asset_index_unavailable" || actual /= reason) $
            Left ("expected asset_index_unavailable/" <> show reason)

-- * Requests

{- | Malformed asset requests: wrong lengths, bad and odd-length hex,
missing and mistyped fields, and a request value that is not an
object.
-}
malformedRequests :: [(String, ByteString)]
malformedRequests =
    [ ("a 27-byte policy id", assetLine (BS.replicate 27 0x11) nameTok)
    , ("a 29-byte policy id", assetLine (BS.replicate 29 0x11) nameTok)
    , ("an empty policy id", assetLine "" nameTok)
    , ("an odd-length policy id", assetLineText (Text.drop 1 (hex policyA)) (hex nameTok))
    , ("a non-hex policy id", assetLineText (Text.replicate 56 "z") (hex nameTok))
    , ("a 0x-prefixed policy id", assetLineText ("0x" <> hex policyA) (hex nameTok))
    , ("a 33-byte asset name", assetLine policyA (BS.replicate 33 0xEE))
    , ("an odd-length asset name", assetLineText (hex policyA) "746f6")
    , ("a non-hex asset name", assetLineText (hex policyA) "tok")
    , ("a missing policy_id", requestOf ["asset_name" .= hex nameTok])
    , ("a missing asset_name", requestOf ["policy_id" .= hex policyA])
    ,
        ( "a numeric policy_id"
        , requestOf ["policy_id" .= (28 :: Int), "asset_name" .= hex nameTok]
        )
    ,
        ( "a null policy_id"
        , requestOf ["policy_id" .= Aeson.Null, "asset_name" .= hex nameTok]
        )
    ,
        ( "an array asset_name"
        , requestOf ["policy_id" .= hex policyA, "asset_name" .= [hex nameTok]]
        )
    ,
        ( "a null asset_name"
        , requestOf ["policy_id" .= hex policyA, "asset_name" .= Aeson.Null]
        )
    , ("an empty request object", requestOf [])
    , ("a string request value", encodeLine ["utxos_with_asset" .= hex policyA])
    , ("a null request value", encodeLine ["utxos_with_asset" .= Aeson.Null])
    ,
        ( "an array request value"
        , encodeLine ["utxos_with_asset" .= [hex policyA, hex nameTok]]
        )
    ]
  where
    requestOf kvs = encodeLine ["utxos_with_asset" .= Aeson.object kvs]

-- * Small helpers

-- | Alternate the case of hex digits: @abcd@ becomes @aBcD@.
mixCase :: Text -> Text
mixCase =
    Text.pack
        . zipWith (\i c -> if odd i then upper c else c) [0 :: Int ..]
        . Text.unpack
  where
    upper c
        | c >= 'a' && c <= 'f' = toEnum (fromEnum c - 32)
        | otherwise = c

genBytes :: Int -> Int -> Gen ByteString
genBytes lo hi = do
    n <- chooseInt (lo, hi)
    BS.pack <$> vectorOf n (oneof [elements [0x00, 0x7F, 0x80, 0xFF], QC.arbitrary])

-- | Run a property inside an example, failing it with QuickCheck's report.
quickCheckIO :: Int -> Property -> IO ()
quickCheckIO n p = do
    result <- quickCheckWithResult stdArgs{maxSuccess = n, chatty = False} p
    unless (isSuccess result) (expectationFailure (output result))
