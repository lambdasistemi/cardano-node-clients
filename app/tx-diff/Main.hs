{- |
Module      : Main
Description : tx-diff executable entry point
License     : Apache-2.0

Thin CLI wrapper over 'Cardano.Node.Client.TxDiff'. It reads two encoded
Conway transaction inputs, optionally resolves their referenced UTxOs via
local N2C or a Blockfrost-compatible web2 endpoint, prints the human
renderer output, and exits with a non-zero status when differences are
present.
-}
module Main (main) where

import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.Provider (mkN2CProvider)
import Cardano.Node.Client.TxDiff (
    CollapseRules,
    HumanRenderOptions (..),
    TxDiffOptions (..),
    decodeConwayTxInput,
    defaultTxDiffOptions,
    diffConwayTxWith,
    diffNodeHasChanges,
    parseCollapseRulesYaml,
    renderDiffNodeHumanWith,
 )
import Cardano.Node.Client.TxDiff.Blueprint (
    Blueprint,
    blueprintDataDecoder,
    parseBlueprintJSON,
 )
import Cardano.Node.Client.TxDiff.Cli (
    TxDiffCliError (..),
    TxDiffCliN2cConfig (..),
    TxDiffCliOptions (..),
    TxDiffCliWeb2Config (..),
    parseTxDiffCliArgs,
    txDiffCliUsage,
 )
import Cardano.Node.Client.TxDiff.Resolver (
    Resolver,
    resolveChain,
 )
import Cardano.Node.Client.TxDiff.Resolver.N2C (n2cResolver)
import Cardano.Node.Client.TxDiff.Resolver.Web2 (
    Web2Config (..),
    httpFetchTx,
    web2Resolver,
 )

import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    inputsTxBodyL,
    referenceInputsTxBodyL,
 )
import Cardano.Ledger.BaseTypes (TxIx (..))
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.Ledger (ConwayTx)

import Cardano.Crypto.Hash (hashToBytes)
import Control.Concurrent.Async (withAsync)
import Control.Monad (void)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as TextIO
import Lens.Micro ((^.))
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Environment (getArgs, getProgName, lookupEnv)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
    args <- getArgs
    either dieUsage runDiff (parseTxDiffCliArgs args)

runDiff :: TxDiffCliOptions -> IO ()
runDiff cliOptions = do
    blueprints <- traverse loadBlueprint (txDiffCliBlueprintPaths cliOptions)
    collapseRules <- traverse loadCollapseRules (txDiffCliCollapseRulesPath cliOptions)
    leftBytes <- BS.readFile (txDiffCliLeftPath cliOptions)
    rightBytes <- BS.readFile (txDiffCliRightPath cliOptions)
    leftTx <- decodeOrDie "left" leftBytes
    rightTx <- decodeOrDie "right" rightBytes
    let inputs = collectInputs leftTx <> collectInputs rightTx
    resolutionResult <-
        if anyResolverConfigured cliOptions
            then do
                (resolved, unresolved) <-
                    withResolverChain cliOptions $ \chain ->
                        resolveChain chain inputs
                reportUnresolved unresolved
                pure (Just resolved)
            else pure Nothing
    let options =
            defaultTxDiffOptions
                { txDiffDecodeData =
                    case blueprints of
                        [] ->
                            Nothing
                        _ ->
                            Just (blueprintDataDecoder blueprints)
                , txDiffResolvedInputs = resolutionResult
                }
        diff = diffConwayTxWith options leftTx rightTx
    TextIO.putStr $
        renderDiffNodeHumanWith
            ( (txDiffCliHumanRenderOptions cliOptions)
                { humanCollapseRules = collapseRules
                }
            )
            diff
    if diffNodeHasChanges diff
        then exitFailure
        else exitSuccess

decodeOrDie :: String -> BS.ByteString -> IO ConwayTx
decodeOrDie side bytes =
    case decodeConwayTxInput bytes of
        Right tx -> pure tx
        Left err -> do
            hPutStrLn stderr ("tx-diff: failed to decode " <> side <> " input: " <> show err)
            exitFailure

collectInputs :: ConwayTx -> Set TxIn
collectInputs tx =
    let body = tx ^. bodyTxL
     in (body ^. inputsTxBodyL)
            <> (body ^. referenceInputsTxBodyL)
            <> (body ^. collateralInputsTxBodyL)

anyResolverConfigured :: TxDiffCliOptions -> Bool
anyResolverConfigured cli =
    case (txDiffCliN2cResolver cli, txDiffCliWeb2Resolver cli) of
        (Nothing, Nothing) -> False
        _ -> True

{- | Build the resolver chain that matches the CLI flags. The N2C resolver
is tried first (cheap, local, no privacy cost); the web2 resolver fills
the remainder.

The continuation owns the resolver lifecycle: if N2C is configured, the
underlying mini-protocol thread is spawned with 'withAsync' and torn down
when the continuation returns.
-}
withResolverChain ::
    TxDiffCliOptions ->
    ([Resolver] -> IO a) ->
    IO a
withResolverChain cli k = do
    web2 <- traverse buildWeb2Resolver (txDiffCliWeb2Resolver cli)
    case txDiffCliN2cResolver cli of
        Nothing ->
            k (maybe [] pure web2)
        Just n2c ->
            withN2cResolver n2c $ \n2cR ->
                k (n2cR : maybe [] pure web2)

buildWeb2Resolver :: TxDiffCliWeb2Config -> IO Resolver
buildWeb2Resolver cfg = do
    apiKey <- loadWeb2ApiKey (txDiffCliWeb2ApiKeyFile cfg)
    manager <- newManager tlsManagerSettings
    pure $
        web2Resolver
            Web2Config
                { web2ResolverName = "web2"
                , web2Fetch =
                    httpFetchTx
                        manager
                        (txDiffCliWeb2Url cfg)
                        apiKey
                }

{- | Resolve the Blockfrost-style @project_id@ key.

Precedence:

1. @--web2-api-key-file PATH@ wins; surrounding whitespace is stripped.
2. Otherwise the @TX_DIFF_WEB2_API_KEY@ environment variable is consulted.
3. With neither set, the request goes out without a key, which works
   against self-hosted Blockfrost-compatible endpoints.

This keeps the secret out of @ps@ output and shell history, matching the
existing repo conventions used by @cardano-tx-generator@.
-}
loadWeb2ApiKey :: Maybe FilePath -> IO (Maybe Text)
loadWeb2ApiKey (Just path) =
    Just . Text.strip . Text.decodeUtf8 <$> BS.readFile path
loadWeb2ApiKey Nothing = do
    envKey <- lookupEnv "TX_DIFF_WEB2_API_KEY"
    pure (fmap (Text.strip . Text.pack) envKey)

withN2cResolver :: TxDiffCliN2cConfig -> (Resolver -> IO a) -> IO a
withN2cResolver TxDiffCliN2cConfig{txDiffCliN2cSocket, txDiffCliN2cNetworkMagic} k = do
    lsqCh <- newLSQChannel 64
    ltxsCh <- newLTxSChannel 64
    withAsync
        ( void $
            runNodeClient
                (NetworkMagic txDiffCliN2cNetworkMagic)
                txDiffCliN2cSocket
                lsqCh
                ltxsCh
        )
        $ \_ -> k (n2cResolver (mkN2CProvider lsqCh))

reportUnresolved :: Map TxIn [Text] -> IO ()
reportUnresolved unresolved
    | Map.null unresolved = pure ()
    | otherwise =
        mapM_ emit (Map.toAscList unresolved)
  where
    emit (TxIn (TxId safeHash) (TxIx ix), names) =
        hPutStrLn stderr $
            "tx-diff: input "
                <> Text.unpack (Text.decodeUtf8 (Base16.encode (hashToBytes (extractHash safeHash))))
                <> "#"
                <> show ix
                <> " not resolved by "
                <> showNames names

    showNames [] = "[]"
    showNames ns = "[" <> Text.unpack (Text.intercalate ", " ns) <> "]"

loadBlueprint :: FilePath -> IO Blueprint
loadBlueprint blueprintPath = do
    input <- LBS.readFile blueprintPath
    case parseBlueprintJSON input of
        Left err -> do
            hPutStrLn
                stderr
                ("tx-diff: failed to decode blueprint " <> blueprintPath <> ": " <> err)
            exitFailure
        Right blueprint ->
            pure blueprint

loadCollapseRules :: FilePath -> IO CollapseRules
loadCollapseRules collapseRulesPath = do
    input <- BS.readFile collapseRulesPath
    case parseCollapseRulesYaml input of
        Left err -> do
            hPutStrLn
                stderr
                ( "tx-diff: failed to decode collapse rules "
                    <> collapseRulesPath
                    <> ": "
                    <> err
                )
            exitFailure
        Right rules ->
            pure rules

dieUsage :: TxDiffCliError -> IO a
dieUsage (TxDiffCliUsageError err) = do
    prog <- getProgName
    hPutStrLn stderr ("tx-diff: " <> err)
    hPutStrLn stderr (txDiffCliUsage prog)
    exitFailure
