{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.AssetQuerySpec
Description : utxos_with_asset through a devnet daemon's socket
License     : Apache-2.0

Boots a real @cardano-node@ devnet, runs the @utxo-indexer@ daemon
against it (RocksDB store, listen socket), and submits five
transactions that mint, move, split, spend and burn a native asset
under a @RequireSignature@ policy. A second policy mints the same
asset name, and the first policy also mints a longer name that starts
with the queried one.

After every transaction the daemon's @utxos_with_asset@ answer for
each of the three assets must equal the node's own ledger view, read
through LocalStateQuery at the holder addresses: the same holders in
ascending TxIn order, with the same quantities and datums. Each
holder's @txout@ must be byte-identical to the daemon's @utxos_at@
bytes for that TxIn, and its @created@ point must equal the daemon's
@await@ observation of it.

Chain-side failures (a rejected submission, a block the daemon never
applies, a step that does not change the chain's holders) stop the
test at once. Answer mismatches are collected and reported together
at the end, so every step runs.
-}
module Cardano.Node.Client.E2E.AssetQuerySpec (spec) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr, serialiseAddr)
import Cardano.Ledger.Allegra.Scripts (mkRequireSignatureTimelock)
import Cardano.Ledger.Api (
    ConwayEra,
    Script,
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    feeTxBodyL,
    hashScript,
    inputsTxBodyL,
    mintTxBodyL,
    mkBasicTx,
    mkBasicTxBody,
    mkBasicTxOut,
    mkBasicTxWits,
    outputsTxBodyL,
    scriptTxWitsL,
    txIdTx,
    valueTxOutL,
    witsTxL,
 )
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (fromNativeScript)
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Hashes (ScriptHash (..), extractHash, originalBytes)
import Cardano.Ledger.Keys (asWitness)
import Cardano.Ledger.Mary.Value qualified as Mary
import Cardano.Ledger.Plutus.Data (Datum (..), makeBinaryData)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (
    Ed25519DSIGN,
    SignKeyDSIGN,
    addKeyWitness,
    devnetMagic,
    enterpriseAddr,
    genesisAddr,
    genesisDir,
    genesisSignKey,
    keyHashFromSignKey,
    mkSignKey,
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Probe (defaultProbeConfig)
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.N2C.Reconnect (defaultReconnectPolicy)
import Cardano.Node.Client.N2C.Submitter (mkN2CSubmitter)
import Cardano.Node.Client.Provider (
    Provider (..),
    queryUTxOsAtH,
 )
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Cardano.Node.Client.UTxOIndexer.WireClient (
    Answer (..),
    Match (..),
    assetLine,
    awaitPoint,
    encodeLine,
    hex,
    hexBytes,
    holderOf,
    requestLine,
    successAnswer,
    txInOrder,
    utxosAt,
 )
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, poll, withAsync)
import Control.Monad (forM_, unless, when)
import Control.Tracer (nullTracer)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Lens.Micro ((&), (.~), (^.))
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Directory (doesPathExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it)

spec :: Spec
spec =
    describe "utxo-indexer socket: utxos_with_asset on a devnet (E2E)" $
        it
            "answers mint, move, split, spend and burn exactly as the chain did"
            runAssetQueryE2E

-- * Keys, policies, assets

policyKeyA, policyKeyB, holderKeyA, holderKeyB :: SignKeyDSIGN Ed25519DSIGN
policyKeyA = mkSignKey "asset-e2e-policy-a-key-seed-0001"
policyKeyB = mkSignKey "asset-e2e-policy-b-key-seed-0001"
holderKeyA = mkSignKey "asset-e2e-holder-a-key-seed-0001"
holderKeyB = mkSignKey "asset-e2e-holder-b-key-seed-0001"

holderA, holderB :: Addr
holderA = enterpriseAddr (keyHashFromSignKey holderKeyA)
holderB = enterpriseAddr (keyHashFromSignKey holderKeyB)

-- | A @RequireSignature@ timelock for the key, as a mint witness.
policyScript :: SignKeyDSIGN Ed25519DSIGN -> Script ConwayEra
policyScript key =
    fromNativeScript
        (mkRequireSignatureTimelock (asWitness (keyHashFromSignKey key)))

scriptA, scriptB :: Script ConwayEra
scriptA = policyScript policyKeyA
scriptB = policyScript policyKeyB

data Asset = Asset
    { assetLabel :: String
    , assetPolicy :: Mary.PolicyID
    , assetName :: Mary.AssetName
    }

tokenA, tokenB, decoyA :: Asset
tokenA = Asset "policy A token" (policyOf scriptA) (Mary.AssetName "e2e-token")
tokenB = Asset "policy B token of the same name" (policyOf scriptB) (Mary.AssetName "e2e-token")
decoyA = Asset "policy A token with a longer name" (policyOf scriptA) (Mary.AssetName "e2e-token-2")

-- | The policy id is the hash of the very script attached as witness.
policyOf :: Script ConwayEra -> Mary.PolicyID
policyOf = Mary.PolicyID . hashScript

assetBytes :: Asset -> (ByteString, ByteString)
assetBytes a =
    ( case assetPolicy a of Mary.PolicyID (ScriptHash h) -> hashToBytes h
    , case assetName a of Mary.AssetName n -> SBS.fromShort n
    )

-- * The five transactions

-- | Lovelace on each output the mint creates for an asset.
assetCoin :: Integer
assetCoin = 10_000_000

-- | The fee of every transaction, well above the devnet minimum.
fee :: Integer
fee = 1_000_000

runAssetQueryE2E :: IO ()
runAssetQueryE2E = do
    gDir <- genesisDir
    withCardanoNode gDir $ \nodeSock _ ->
        withSystemTempDirectory "asset-query-e2e" $ \tmp -> do
            let daemonSock = tmp </> "indexer.sock"
                NetworkMagic magic = devnetMagic
                cfg =
                    DaemonConfig
                        { dcRelaySocket = nodeSock
                        , dcListenSocket = daemonSock
                        , dcNetworkMagic = magic
                        , dcByronEpochSlots = 42
                        , dcReadyThresholdSlots = 60
                        , dcSecurityParamK = 2160
                        , dcDbPath = Just (tmp </> "db")
                        , dcReconnectPolicy = defaultReconnectPolicy
                        , dcProbeConfig = defaultProbeConfig
                        , dcStaleAfterSeconds = 600
                        }
            withAsync (runDaemon nullTracer cfg) $ \daemon -> do
                waitForFile daemonSock 600
                requireRunning daemon "after binding its socket"
                waitReady daemonSock 120
                withNodeClient nodeSock $ \provider submitter -> do
                    mismatches <- newIORef []
                    let ctx = Ctx daemonSock provider submitter mismatches
                    driveSteps ctx
                    requireRunning daemon "after the last step"
                    found <- readIORef mismatches
                    unless (null found) $
                        expectationFailure (unlines (reverse found))

driveSteps :: Ctx -> IO ()
driveSteps ctx = do
    genesis <- queryUTxOs (ctxProvider ctx) genesisAddr
    (gIn, gOut) <- case genesis of
        g : _ -> pure g
        [] -> fail "setup: no genesis UTxO"
    let gCoin = unCoin (gOut ^. coinTxOutL)
        mintTx =
            assetTx
                (Set.singleton gIn)
                [ out holderA assetCoin [(tokenA, 1)] NoDatum
                , out holderA assetCoin [(tokenA, 2)] inlineDatum
                , out holderB assetCoin [(tokenB, 5)] NoDatum
                , out holderB assetCoin [(decoyA, 3)] NoDatum
                , out genesisAddr (gCoin - 4 * assetCoin - fee) [] NoDatum
                ]
                (minted [(tokenA, 3), (tokenB, 5), (decoyA, 3)])
                [scriptA, scriptB]
                [genesisSignKey, policyKeyA, policyKeyB]
    v1 <- step ctx "mint" Map.empty mintTx
    holdersOf v1 tokenA `requireCount` 2

    let o0 = TxIn (txIdTx mintTx) (TxIx 0)
        o1 = TxIn (txIdTx mintTx) (TxIx 1)
    c0 <- coinIn v1 o0
    let moveTx =
            assetTx
                (Set.singleton o0)
                [out holderB (c0 - fee) [(tokenA, 1)] NoDatum]
                mempty
                []
                [holderKeyA]
    v2 <- step ctx "move" v1 moveTx

    c1 <- coinIn v2 o1
    let half = (c1 - fee) `div` 2
        splitTx =
            assetTx
                (Set.singleton o1)
                [ out holderA half [(tokenA, 1)] NoDatum
                , out holderA (c1 - fee - half) [(tokenA, 1)] NoDatum
                ]
                mempty
                []
                [holderKeyA]
    v3 <- step ctx "split" v2 splitTx
    holdersOf v3 tokenA `requireCount` 3

    let m0 = TxIn (txIdTx moveTx) (TxIx 0)
        s0 = TxIn (txIdTx splitTx) (TxIx 0)
        s1 = TxIn (txIdTx splitTx) (TxIx 1)
    cm0 <- coinIn v3 m0
    cs0 <- coinIn v3 s0
    let spendTx =
            assetTx
                (Set.fromList [m0, s0])
                [out holderA (cm0 + cs0 - fee) [(tokenA, 2)] NoDatum]
                mempty
                []
                [holderKeyA, holderKeyB]
    v4 <- step ctx "spend" v3 spendTx

    let k0 = TxIn (txIdTx spendTx) (TxIx 0)
    ck0 <- coinIn v4 k0
    cs1 <- coinIn v4 s1
    let burnTx =
            assetTx
                (Set.fromList [k0, s1])
                [out holderA (ck0 + cs1 - fee) [] NoDatum]
                (minted [(tokenA, -3)])
                [scriptA]
                [holderKeyA, policyKeyA]
    v5 <- step ctx "burn" v4 burnTx
    holdersOf v5 tokenA `requireCount` 0

{- | Submit one transaction, wait until the daemon applied its block,
read the node's view of the holder addresses, require the chain's
holders of the queried asset to have changed, and compare the
daemon's answer for every asset with that view.
-}
step :: Ctx -> String -> View -> ConwayTx -> IO View
step ctx name previous tx = do
    submitTx (ctxSubmitter ctx) tx >>= \case
        Submitted _ -> pure ()
        Rejected why -> fail ("setup: " <> name <> " rejected: " <> show why)
    _ <- awaitPoint (ctxSock ctx) (wireTxIn (TxIn (txIdTx tx) (TxIx 0))) 120
    view <- nodeView (ctxProvider ctx)
    when (map fst (holdersOf view tokenA) == map fst (holdersOf previous tokenA)) $
        fail ("setup: " <> name <> " left the chain's holders of the token unchanged")
    forM_ [tokenA, tokenB, decoyA] (compareAsset ctx name view)
    pure view

-- | The node's UTxO at the two holder addresses, from one acquired snapshot.
nodeView :: Provider IO -> IO View
nodeView provider = do
    byAddress <-
        withAcquired provider $ \h ->
            queryUTxOsAtH h (Set.fromList [holderA, holderB])
    pure (Map.fromList (concat (Map.elems byAddress)))

compareAsset :: Ctx -> String -> View -> Asset -> IO ()
compareAsset ctx name view asset = do
    let (policy, assetNameBytes) = assetBytes asset
        expected = holdersOf view asset
        report msg = modifyIORef' (ctxMismatches ctx) ((name <> ", " <> assetLabel asset <> ": " <> msg) :)
    resp <- requestLine (ctxSock ctx) (assetLine policy assetNameBytes)
    case successAnswer resp of
        Left why -> report (why <> "; answer was " <> show resp)
        Right answer
            | map holderOf (ansMatches answer) /= map fst expected ->
                report
                    ( "holders "
                        <> show (map holderOf (ansMatches answer))
                        <> ", the chain has "
                        <> show (map fst expected)
                    )
            | otherwise -> forM_ (zip (ansMatches answer) (map snd expected)) $ \(m, o) -> do
                raw <- hexBytes (mTxOut m)
                live <- utxosAt (ctxSock ctx) (serialiseAddr (o ^. addrTxOutL))
                when (lookup (mTxIn m) live /= Just raw) $
                    report (Text.unpack (mTxIn m) <> ": txout differs from utxos_at")
                observed <- awaitPoint (ctxSock ctx) (mTxIn m) 10
                when (mCreated m /= observed) $
                    report
                        ( Text.unpack (mTxIn m)
                            <> ": created "
                            <> show (mCreated m)
                            <> ", await "
                            <> show observed
                        )
                when (fst (mCreated m) > fst (ansPoint answer)) $
                    report (Text.unpack (mTxIn m) <> ": created after the answer's point")
                when (mDatum m /= datumJson o) $
                    report
                        ( Text.unpack (mTxIn m)
                            <> ": datum "
                            <> show (mDatum m)
                            <> ", the chain has "
                            <> show (datumJson o)
                        )

-- * The chain's view

type View = Map TxIn (Ledger.TxOut ConwayEra)

{- | The holders of an asset in a node view, as wire @(txin,
quantity)@ pairs with their outputs, in ascending TxIn order.
-}
holdersOf :: View -> Asset -> [((Text, Text), Ledger.TxOut ConwayEra)]
holdersOf view asset =
    sortOn
        (txInOrder . fst . fst)
        [ ((wireTxIn t, Text.pack (show q)), o)
        | (t, o) <- Map.toList view
        , let q = quantityOf asset o
        , q > 0
        ]

quantityOf :: Asset -> Ledger.TxOut ConwayEra -> Integer
quantityOf asset o =
    Mary.lookupMultiAsset (assetPolicy asset) (assetName asset) (o ^. valueTxOutL)

-- | The wire datum the chain's output implies (wire schema v1).
datumJson :: Ledger.TxOut ConwayEra -> KM.KeyMap Aeson.Value
datumJson o = case o ^. datumTxOutL of
    NoDatum -> KM.fromList [("kind", "none")]
    DatumHash h ->
        KM.fromList
            [("kind", "hash"), ("hash", Aeson.String (hex (hashToBytes (extractHash h))))]
    Datum d ->
        KM.fromList [("kind", "inline"), ("cbor", Aeson.String (hex (originalBytes d)))]

requireCount :: [a] -> Int -> IO ()
requireCount xs n =
    when (length xs /= n) $
        fail ("setup: the chain holds the token in " <> show (length xs) <> " outputs, not " <> show n)

coinIn :: View -> TxIn -> IO Integer
coinIn view t =
    maybe
        (fail ("setup: " <> Text.unpack (wireTxIn t) <> " is not in the node's view"))
        (pure . unCoin . (^. coinTxOutL))
        (Map.lookup t view)

wireTxIn :: TxIn -> Text
wireTxIn (TxIn (TxId h) (TxIx ix)) =
    hex (hashToBytes (extractHash h)) <> "#" <> Text.pack (show ix)

-- * Building transactions

out ::
    Addr ->
    Integer ->
    [(Asset, Integer)] ->
    Datum ConwayEra ->
    Ledger.TxOut ConwayEra
out addr lovelace assets datum =
    mkBasicTxOut
        addr
        ( Mary.valueFromList
            (Coin lovelace)
            [(assetPolicy a, assetName a, q) | (a, q) <- assets]
        )
        & datumTxOutL .~ datum

-- | The inline datum @I 42@.
inlineDatum :: Datum ConwayEra
inlineDatum = Datum (either error id (makeBinaryData "\x18\x2A"))

minted :: [(Asset, Integer)] -> Mary.MultiAsset
minted xs = Mary.multiAssetFromList [(assetPolicy a, assetName a, q) | (a, q) <- xs]

{- | A signed transaction spending the inputs, paying the outputs and
minting (or burning) the given value, with each policy script in the
witness set.
-}
assetTx ::
    Set TxIn ->
    [Ledger.TxOut ConwayEra] ->
    Mary.MultiAsset ->
    [Script ConwayEra] ->
    [SignKeyDSIGN Ed25519DSIGN] ->
    ConwayTx
assetTx ins outs mint scripts =
    foldr addKeyWitness unsigned
  where
    body =
        mkBasicTxBody
            & inputsTxBodyL .~ ins
            & outputsTxBodyL .~ StrictSeq.fromList outs
            & feeTxBodyL .~ Coin fee
            & mintTxBodyL .~ mint
    unsigned =
        mkBasicTx body
            & witsTxL
                .~ ( mkBasicTxWits
                        & scriptTxWitsL
                            .~ Map.fromList [(hashScript s, s) | s <- scripts]
                   )

-- * Daemon and node plumbing

data Ctx = Ctx
    { ctxSock :: FilePath
    , ctxProvider :: Provider IO
    , ctxSubmitter :: Submitter IO
    , ctxMismatches :: IORef [String]
    }

withNodeClient :: FilePath -> (Provider IO -> Submitter IO -> IO a) -> IO a
withNodeClient nodeSock action = do
    lsq <- newLSQChannel 16
    ltxs <- newLTxSChannel 16
    withAsync (runNodeClient devnetMagic nodeSock lsq ltxs) $ \client -> do
        threadDelay 3_000_000
        poll client >>= \case
            Nothing -> action (mkN2CProvider lsq) (mkN2CSubmitter ltxs)
            Just r -> fail ("setup: node client stopped: " <> show r)

requireRunning :: Async () -> String -> IO ()
requireRunning daemon ctx =
    poll daemon >>= \case
        Nothing -> pure ()
        Just r -> fail ("setup: daemon stopped " <> ctx <> ": " <> show r)

waitReady :: FilePath -> Int -> IO ()
waitReady _ 0 = fail "setup: daemon never became ready"
waitReady sock n = do
    resp <- requestLine sock (encodeLine ["ready" .= Aeson.Null])
    case Aeson.decodeStrict' resp of
        Just (Aeson.Object o) | KM.lookup "ready" o == Just (Aeson.Bool True) -> pure ()
        _ -> threadDelay 1_000_000 >> waitReady sock (n - 1)

waitForFile :: FilePath -> Int -> IO ()
waitForFile path = go
  where
    go 0 = fail ("setup: nothing appeared at " <> path)
    go n = do
        present <- doesPathExist path
        if present then pure () else threadDelay 100_000 >> go (n - 1)
