{- |
Module      : Main
Description : cardano-tx-generator daemon entry point
License     : Apache-2.0

CLI parsing only; everything else lives in
'Cardano.Node.Client.TxGenerator.Daemon.runDaemon'. CLI
shape mirrors @specs/034-cardano-tx-generator/quickstart.md@.
-}
module Main (main) where

import Cardano.Node.Client.N2C.Probe (
    ProbeConfig (..),
    defaultProbeConfig,
 )
import Cardano.Node.Client.N2C.Reconnect (
    ReconnectPolicy (..),
    defaultReconnectPolicy,
 )
import Cardano.Node.Client.TxGenerator.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Data.Maybe (fromMaybe)
import Data.Word (Word64)
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

defaultByronEpochSlots :: Word
defaultByronEpochSlots = 432000

defaultAwaitTimeoutSeconds :: Word
defaultAwaitTimeoutSeconds = 30

defaultReadyThresholdSlots :: Word
defaultReadyThresholdSlots = 10

defaultSecurityParamK :: Word
defaultSecurityParamK = 2160

{- | Parse a single @--key value@ pair from the argument
list. Returns the value and the remaining args.
-}
takeFlag :: String -> [String] -> Maybe (String, [String])
takeFlag _ [] = Nothing
takeFlag key args = go [] args
  where
    go _ [] = Nothing
    go seen (k : v : rest)
        | k == key = Just (v, reverse seen ++ rest)
    go seen (x : rest) = go (x : seen) rest

parseConfig :: [String] -> IO DaemonConfig
parseConfig args0 = do
    (relay, args1) <- requireFlag "--relay-socket" args0
    (control, args2) <- requireFlag "--control-socket" args1
    (stateDir, args3) <- requireFlag "--state-dir" args2
    (masterSeed, args4) <- requireFlag "--master-seed-file" args3
    (faucetSkey, args5) <- requireFlag "--faucet-skey-file" args4
    (magicS, args6) <- requireFlag "--network-magic" args5
    let (slotsS, args7) =
            fromMaybe
                (show defaultByronEpochSlots, args6)
                (takeFlag "--byron-epoch-slots" args6)
        (timeoutS, args8) =
            fromMaybe
                (show defaultAwaitTimeoutSeconds, args7)
                (takeFlag "--await-timeout-seconds" args7)
        (readyS, args9) =
            fromMaybe
                (show defaultReadyThresholdSlots, args8)
                (takeFlag "--ready-threshold-slots" args8)
        (kS, args10) =
            fromMaybe
                (show defaultSecurityParamK, args9)
                (takeFlag "--security-param-k" args9)
        (mDb, args11) = case takeFlag "--db-path" args10 of
            Just (p, rest) -> (Just p, rest)
            Nothing -> (Nothing, args10)
        (initialMsS, args12) =
            fromMaybe
                (show (rpInitialMs defaultReconnectPolicy), args11)
                (takeFlag "--reconnect-initial-ms" args11)
        (maxMsS, args13) =
            fromMaybe
                (show (rpMaxMs defaultReconnectPolicy), args12)
                (takeFlag "--reconnect-max-ms" args12)
        (resetMsS, args14) =
            fromMaybe
                ( show (rpResetThresholdMs defaultReconnectPolicy)
                , args13
                )
                (takeFlag "--reconnect-reset-threshold-ms" args13)
        (mTotalMs, args15) = case takeFlag "--node-ready-timeout-ms" args14 of
            Just (s, rest) -> (Just s, rest)
            Nothing -> (Nothing, args14)
    case args15 of
        [] -> pure ()
        extra -> dieUsage $ "Unexpected args: " <> show extra
    magic <- requireWord "--network-magic" magicS
    slots <- requireWord "--byron-epoch-slots" slotsS
    timeout <- requireWord "--await-timeout-seconds" timeoutS
    ready <- requireWord "--ready-threshold-slots" readyS
    k <- requireWord "--security-param-k" kS
    initialMs <- requireWord "--reconnect-initial-ms" initialMsS
    maxMs <- requireWord "--reconnect-max-ms" maxMsS
    resetMs <-
        requireWord "--reconnect-reset-threshold-ms" resetMsS
    mTotalMsParsed <- case mTotalMs of
        Nothing -> pure Nothing
        Just s ->
            Just <$> requireWord "--node-ready-timeout-ms" s
    let policy =
            ReconnectPolicy
                { rpInitialMs = fromIntegral (initialMs :: Word)
                , rpMaxMs = fromIntegral (maxMs :: Word)
                , rpResetThresholdMs =
                    fromIntegral (resetMs :: Word)
                }
        probe =
            defaultProbeConfig
                { pcTotalTimeoutMs =
                    fmap
                        (fromIntegral :: Word -> Word64)
                        mTotalMsParsed
                }
    pure
        DaemonConfig
            { dcRelaySocket = relay
            , dcControlSocket = control
            , dcStateDir = stateDir
            , dcMasterSeedFile = masterSeed
            , dcFaucetSKeyFile = faucetSkey
            , dcNetworkMagic = fromIntegral (magic :: Word)
            , dcByronEpochSlots = fromIntegral (slots :: Word)
            , dcAwaitTimeoutSeconds = fromIntegral (timeout :: Word)
            , dcReadyThresholdSlots = fromIntegral (ready :: Word)
            , dcSecurityParamK = fromIntegral (k :: Word)
            , dcDbPath = mDb
            , dcReconnectPolicy = policy
            , dcProbeConfig = probe
            }
  where
    requireFlag key args =
        maybe
            (dieUsage $ "Missing required flag: " <> key)
            pure
            (takeFlag key args)
    requireWord key s =
        maybe
            ( dieUsage $
                key
                    <> " expects a non-negative integer, got: "
                    <> s
            )
            pure
            (readMaybe s)

dieUsage :: String -> IO a
dieUsage msg = do
    prog <- getProgName
    hPutStrLn stderr msg
    hPutStrLn stderr ""
    hPutStrLn stderr $ "Usage: " <> prog <> " \\"
    hPutStrLn stderr "  --relay-socket PATH \\"
    hPutStrLn stderr "  --control-socket PATH \\"
    hPutStrLn stderr "  --state-dir DIR \\"
    hPutStrLn stderr "  --master-seed-file PATH \\"
    hPutStrLn stderr "  --faucet-skey-file PATH \\"
    hPutStrLn stderr "  --network-magic INT \\"
    hPutStrLn stderr "  [--byron-epoch-slots INT] \\"
    hPutStrLn stderr "  [--await-timeout-seconds INT] \\"
    hPutStrLn stderr "  [--ready-threshold-slots INT] \\"
    hPutStrLn stderr "  [--security-param-k INT] \\"
    hPutStrLn stderr "  [--db-path DIR] \\"
    hPutStrLn stderr "  [--reconnect-initial-ms INT] \\"
    hPutStrLn stderr "  [--reconnect-max-ms INT] \\"
    hPutStrLn stderr "  [--reconnect-reset-threshold-ms INT] \\"
    hPutStrLn stderr "  [--node-ready-timeout-ms INT]"
    exitFailure

main :: IO ()
main = do
    args <- getArgs
    cfg <- parseConfig args
    hPutStrLn stderr $ "cardano-tx-generator: " <> show cfg
    runDaemon cfg
