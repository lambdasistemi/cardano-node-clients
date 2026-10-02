{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.DisclosureWireSpec
Description : network, coverage, freshness and limits on the asset answer
License     : Apache-2.0

Speaks the real Unix socket of 'runServer' over a seeded indexer and
reads the four disclosure members of every successful
@utxos_with_asset@ answer: @network@, @coverage@, @freshness@ and
@limits@.

The disclosure handed to the server and the readiness it samples are
the test's inputs; the expected values are derived from them and from
the answer's own @point@, which the test reads back from the answer
rather than typing. Each status is reached through the readiness the
server samples after its storage read, with the clock the server
itself reads: a stale answer is produced by a last progress far enough
in the past, not by a typed age.
-}
module Cardano.Node.Client.UTxOIndexer.DisclosureWireSpec (spec) where

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
import Cardano.Node.Client.UTxOIndexer.Server (
    ReadyStatus (..),
    runServer,
 )
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    BlockHash (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Cardano.Node.Client.UTxOIndexer.WireClient (
    assetLine,
    decoded,
    hex,
    objectWithKeys,
    requestLine,
    withSocketServer,
 )
import Control.Monad (forM_, void)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, newIORef, writeIORef)
import Data.IORef qualified as IORef
import Data.Text (Text)
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Word (Word32, Word64, Word8)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldSatisfy,
 )

spec :: Spec
spec = describe "utxo-indexer socket: utxos_with_asset discloses network, coverage and freshness" $ do
    describe "network" $
        it "states the magic of the disclosure the server was given" $
            forM_ [0, 1, 2, 42, 764_824_073, maxBound :: Word32] $ \magic ->
                withDisclosed fullCoverage{dsNetworkMagic = magic} $ \env -> do
                    setSynced env
                    answer <- askHolders env
                    dNetwork answer
                        `shouldBe` Aeson.object ["magic" .= magic]

    describe "coverage" $ do
        forM_ coverageCases $ \(label, coverage, expected) ->
            it ("states " <> label) $
                withDisclosed fullCoverage{dsCoverage = coverage} $ \env -> do
                    setSynced env
                    answer <- askHolders env
                    dCoverage answer `shouldBe` expected

    describe "freshness" $ do
        it "is synced, with no limit, when connected, recent and within the ready threshold" $
            withDisclosed fullCoverage $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                setReady env (connected at (Just (point + 3)))
                answer <- askHolders env
                status answer `shouldBe` "synced"
                dLimits answer `shouldBe` []
                tipSlot answer `shouldBe` Just (point + 3)
                slotsBehind answer `shouldBe` Just 3

        it "is catching_up one slot past the ready threshold" $
            withDisclosed fullCoverage $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                let tip = point + dsReadyThresholdSlots fullCoverage + 1
                setReady env (connected at (Just tip))
                answer <- askHolders env
                status answer `shouldBe` "catching_up"
                dLimits answer `shouldBe` ["catching_up"]
                slotsBehind answer
                    `shouldBe` Just (dsReadyThresholdSlots fullCoverage + 1)

        it "is synced exactly at the ready threshold" $
            withDisclosed fullCoverage $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                let tip = point + dsReadyThresholdSlots fullCoverage
                setReady env (connected at (Just tip))
                answer <- askHolders env
                status answer `shouldBe` "synced"

        it "is catching_up with null tip and lag while the upstream tip is unknown" $
            withDisclosed fullCoverage $ \env -> do
                at <- getCurrentTime
                setReady env (connected at Nothing)
                answer <- askHolders env
                status answer `shouldBe` "catching_up"
                tipSlot answer `shouldBe` Nothing
                slotsBehind answer `shouldBe` Nothing
                dLimits answer `shouldBe` ["catching_up"]

        it "is disconnected while the supervisor reports the upstream down, even if stale and behind" $
            withDisclosed fullCoverage $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                let longAgo = addUTCTime (negate 10_000) at
                setReady
                    env
                    (connected longAgo (Just (point + 5_000)))
                        { rsUpstream = UpstreamDisconnected (DisconnectInfo "bearer-closed" 3 4_200)
                        }
                answer <- askHolders env
                status answer `shouldBe` "disconnected"
                dLimits answer `shouldBe` ["disconnected"]

        it "is stale when connected with no progress for longer than the bound, even if behind" $
            withDisclosed fullCoverage $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                let bound = dsStaleAfterSeconds fullCoverage
                    lastProgress = addUTCTime (negate (fromIntegral bound + 30)) at
                setReady env (connected lastProgress (Just (point + 5_000)))
                answer <- askHolders env
                status answer `shouldBe` "stale"
                dLimits answer `shouldBe` ["stale"]
                secondsSince answer `shouldSatisfy` (>= bound + 30)

        it "reports the whole seconds since the last progress" $
            withDisclosed fullCoverage $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                setReady env (connected (addUTCTime (-7) at) (Just point))
                answer <- askHolders env
                secondsSince answer `shouldSatisfy` (\s -> s >= 7 && s < 60)

        it "measures slotsBehind from the answer's point, not the processed slot" $
            withDisclosed fullCoverage $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                let tip = point + 40
                setReady
                    env
                    (connected at (Just tip))
                        { rsProcessedSlot = Just (SlotNo tip)
                        , rsSlotsBehind = Just 0
                        }
                answer <- askHolders env
                dPoint answer `shouldBe` point
                slotsBehind answer `shouldBe` Just (tip - dPoint answer)

        it "clamps slotsBehind at zero when the tip is behind the point" $
            withDisclosed fullCoverage $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                setReady env (connected at (Just (point - 2)))
                answer <- askHolders env
                slotsBehind answer `shouldBe` Just 0
                status answer `shouldBe` "synced"

    describe "limits" $ do
        it "names the address filter and partial history beside the freshness limit" $
            withDisclosed partialFiltered $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                let lastProgress =
                        addUTCTime
                            (negate (fromIntegral (dsStaleAfterSeconds partialFiltered) + 5))
                            at
                setReady env (connected lastProgress (Just point))
                answer <- askHolders env
                dLimits answer
                    `shouldBe` ["address_filter", "partial_history", "stale"]

        it "names coverage limits even when synced" $
            withDisclosed partialFiltered $ \env -> do
                setSynced env
                answer <- askHolders env
                status answer `shouldBe` "synced"
                dLimits answer `shouldBe` ["address_filter", "partial_history"]

        it "names coverage_unknown first, and no partial history, for an unknown coverage" $
            withDisclosed unknownCoverage $ \env -> do
                setSynced env
                atTip <- askHolders env
                dLimits atTip `shouldBe` ["coverage_unknown"]
                point <- learnPoint env
                at <- getCurrentTime
                setReady env (connected at (Just (point + 999)))
                behind <- askHolders env
                dLimits behind `shouldBe` ["coverage_unknown", "catching_up"]

        it "is carried whether utxos is empty or not" $
            withDisclosed partialFiltered $ \env -> do
                point <- learnPoint env
                at <- getCurrentTime
                setReady env (connected at (Just (point + 999)))
                holders <- askHolders env
                nobody <- askAsset env noHolderAsset
                length (dUtxos holders) `shouldSatisfy` (> 1)
                dUtxos nobody `shouldBe` []
                dLimits holders
                    `shouldBe` ["address_filter", "partial_history", "catching_up"]
                dLimits nobody `shouldBe` dLimits holders

    describe "shape" $ do
        it "adds exactly network, coverage, freshness and limits to the v1 success answer" $
            withDisclosed fullCoverage $ \env -> do
                setSynced env
                resp <- requestLine (envSock env) (uncurry assetLine heldAsset)
                either expectationFailure (const (pure ())) $ do
                    _ <- objectWithKeys successKeys =<< decoded resp
                    pure ()

        it "freshness carries exactly status, tipSlot, slotsBehind and secondsSinceProgress" $
            withDisclosed fullCoverage $ \env -> do
                setSynced env
                answer <- askHolders env
                either expectationFailure (const (pure ())) $
                    void $
                        objectWithKeys
                            ["secondsSinceProgress", "slotsBehind", "status", "tipSlot"]
                            (dFreshness answer)

        it "leaves invalid_asset_query and asset_index_unavailable without disclosure" $ do
            withDisclosed fullCoverage $ \env -> do
                setSynced env
                resp <- requestLine (envSock env) (assetLine (BS.replicate 27 0x11) "tok")
                either expectationFailure (const (pure ())) $
                    void (objectWithKeys ["detail", "error"] =<< decoded resp)
            withInMemoryIndexer $ \h -> do
                ref <- newIORef =<< synced
                withSocketServer (\p -> runServer p h fullCoverage (IORef.readIORef ref)) $ \sock -> do
                    resp <- requestLine sock (uncurry assetLine heldAsset)
                    either expectationFailure (const (pure ())) $
                        void (objectWithKeys ["error", "reason"] =<< decoded resp)
  where
    synced = do
        at <- getCurrentTime
        pure (connected at Nothing)

-- * Disclosures

fullCoverage :: Disclosure
fullCoverage =
    Disclosure
        { dsNetworkMagic = 42
        , dsCoverage = Coverage FromOrigin AllAddresses
        , dsReadyThresholdSlots = 60
        , dsStaleAfterSeconds = 600
        }

partialFiltered :: Disclosure
partialFiltered =
    fullCoverage
        { dsCoverage =
            Coverage
                (FromPoint (SlotNo 3) (BlockHash (BS.replicate 32 0x03)))
                FilteredAddresses
        , dsStaleAfterSeconds = 30
        }

unknownCoverage :: Disclosure
unknownCoverage = fullCoverage{dsCoverage = Coverage StartUnknown AddressesUnknown}

coverageCases :: [(String, Coverage, Aeson.Value)]
coverageCases =
    [
        ( "origin over all addresses"
        , Coverage FromOrigin AllAddresses
        , Aeson.object ["start" .= ("origin" :: Text), "addresses" .= ("all" :: Text)]
        )
    ,
        ( "origin over a filtered address set"
        , Coverage FromOrigin FilteredAddresses
        , Aeson.object ["start" .= ("origin" :: Text), "addresses" .= ("filtered" :: Text)]
        )
    ,
        ( "a start point over all addresses"
        , Coverage (FromPoint (SlotNo 4) (BlockHash startHash)) AllAddresses
        , Aeson.object
            [ "start" .= Aeson.object ["slot" .= (4 :: Int), "blockHash" .= hex startHash]
            , "addresses" .= ("all" :: Text)
            ]
        )
    ,
        ( "a start point over a filtered address set"
        , Coverage
            (FromPoint (SlotNo 18_446_744_073_709_551_615) (BlockHash startHash))
            FilteredAddresses
        , Aeson.object
            [ "start"
                .= Aeson.object
                    [ "slot" .= (18_446_744_073_709_551_615 :: Word64)
                    , "blockHash" .= hex startHash
                    ]
            , "addresses" .= ("filtered" :: Text)
            ]
        )
    ,
        ( "unknown start and unknown addresses for a store that does not know its coverage"
        , Coverage StartUnknown AddressesUnknown
        , Aeson.object ["start" .= ("unknown" :: Text), "addresses" .= ("unknown" :: Text)]
        )
    ]
  where
    startHash = BS.pack [0 .. 31]

-- * Server under test

data Env = Env
    { envSock :: FilePath
    , envReady :: IORef ReadyStatus
    }

{- | A seeded store served under the given disclosure, with a
readiness the test sets before each request.
-}
withDisclosed :: Disclosure -> (Env -> IO a) -> IO a
withDisclosed disclosure action =
    withInMemoryIndexer $ \h -> do
        seedFixture h
        at <- getCurrentTime
        ref <- newIORef (connected at Nothing)
        withSocketServer (\p -> runServer p h disclosure (IORef.readIORef ref)) $ \sock ->
            action (Env sock ref)

setReady :: Env -> ReadyStatus -> IO ()
setReady env = writeIORef (envReady env)

-- | Connected, progressed now, tip at the point.
setSynced :: Env -> IO ()
setSynced env = do
    point <- learnPoint env
    at <- getCurrentTime
    setReady env (connected at (Just point))

{- | A connected readiness with the given last progress and tip; the
fields the answer must not read are set to values that would mislead
it.
-}
connected :: UTCTime -> Maybe Word64 -> ReadyStatus
connected lastProgress tip =
    ReadyStatus
        { rsReady = False
        , rsTipSlot = SlotNo <$> tip
        , rsProcessedSlot = Just (SlotNo 1)
        , rsSlotsBehind = Just 123_456
        , rsUpstream = UpstreamConnected
        , rsLastProgress = lastProgress
        }

-- | The point the server answers with, read from an answer.
learnPoint :: Env -> IO Word64
learnPoint env = dPoint <$> askHolders env

-- * Reading the answer

data Disclosed = Disclosed
    { dPoint :: Word64
    , dUtxos :: [Aeson.Value]
    , dNetwork :: Aeson.Value
    , dCoverage :: Aeson.Value
    , dFreshness :: Aeson.Value
    , dLimits :: [Text]
    }

successKeys :: [Text]
successKeys = ["coverage", "freshness", "limits", "network", "point", "utxos"]

askHolders :: Env -> IO Disclosed
askHolders env = askAsset env heldAsset

askAsset :: Env -> (ByteString, ByteString) -> IO Disclosed
askAsset env asset = do
    resp <- requestLine (envSock env) (uncurry assetLine asset)
    either (\why -> fail (why <> "; answer was " <> show resp)) pure $
        readDisclosed resp

readDisclosed :: ByteString -> Either String Disclosed
readDisclosed resp = do
    top <- objectWithKeys successKeys =<< decoded resp
    point <- case KM.lookup "point" top of
        Just (Aeson.Object p) -> wordAt "slot" p
        other -> Left ("point: " <> show other)
    utxos <- case KM.lookup "utxos" top of
        Just (Aeson.Array xs) -> Right (foldr (:) [] xs)
        other -> Left ("utxos: " <> show other)
    limits <- case KM.lookup "limits" top of
        Just (Aeson.Array xs) -> traverse limitText (foldr (:) [] xs)
        other -> Left ("limits: " <> show other)
    Disclosed point utxos
        <$> member "network" top
        <*> member "coverage" top
        <*> member "freshness" top
        <*> pure limits
  where
    member k o = maybe (Left ("missing " <> show k)) Right (KM.lookup k o)
    limitText = \case
        Aeson.String t -> Right t
        other -> Left ("limit is not a string: " <> show other)

freshnessField :: Aeson.Key -> Disclosed -> Maybe Aeson.Value
freshnessField k d = case dFreshness d of
    Aeson.Object o -> KM.lookup k o
    _ -> Nothing

status :: Disclosed -> Text
status d = case freshnessField "status" d of
    Just (Aeson.String t) -> t
    other -> error ("status: " <> show other)

tipSlot :: Disclosed -> Maybe Word64
tipSlot = nullableWord "tipSlot"

slotsBehind :: Disclosed -> Maybe Word64
slotsBehind = nullableWord "slotsBehind"

secondsSince :: Disclosed -> Word64
secondsSince d = case freshnessField "secondsSinceProgress" d of
    Just v | Aeson.Success w <- Aeson.fromJSON @Word64 v -> w
    other -> error ("secondsSinceProgress: " <> show other)

nullableWord :: Aeson.Key -> Disclosed -> Maybe Word64
nullableWord k d = case freshnessField k d of
    Just Aeson.Null -> Nothing
    Just v | Aeson.Success w <- Aeson.fromJSON @Word64 v -> Just w
    other -> error (show k <> ": " <> show other)

wordAt :: Aeson.Key -> KM.KeyMap Aeson.Value -> Either String Word64
wordAt k o = case KM.lookup k o of
    Just v | Aeson.Success w <- Aeson.fromJSON @Word64 v -> Right w
    other -> Left (show k <> ": " <> show other)

-- * Fixture: two blocks, two holders of one asset

assetPolicy :: ByteString
assetPolicy = BS.replicate 28 0x11

heldAsset :: (ByteString, ByteString)
heldAsset = (assetPolicy, "tok")

noHolderAsset :: (ByteString, ByteString)
noHolderAsset = (assetPolicy, "none")

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
            (TxIn (BS.replicate 32 0x5A) ix)
            (Address (serialiseAddr (addressOf a)))
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

addressOf :: Word8 -> Addr
addressOf b =
    Addr
        Testnet
        (KeyHashObj (KeyHash (UnsafeHash (SBS.toShort (BS.replicate 28 b)))))
        StakeRefNull
