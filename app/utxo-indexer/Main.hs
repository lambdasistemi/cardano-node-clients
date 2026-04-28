{- |
Module      : Main
Description : utxo-indexer daemon entrypoint
License     : Apache-2.0

Minimal address->UTxO indexer daemon. Follows the chain
via N2C ChainSync from one relay socket, maintains an
in-memory address->UTxO index, exposes two read
primitives (@utxos_at@, @await@) plus a @ready@ probe
over a Unix domain socket using newline-delimited JSON.

This @Main@ is just CLI parsing; everything else lives
in 'Cardano.Node.Client.UTxOIndexer.Daemon.runDaemon'.
-}
module Main (main) where

import Cardano.Node.Client.UTxOIndexer.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Data.Maybe (fromMaybe)
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

-- | Default ready threshold (slots).
defaultReadyThreshold :: Word
defaultReadyThreshold = 60

{- | Default Cardano security parameter @k@ — the
rollback log is capped at this many of the most-recent
entries (per-block, not per-slot). Mainnet/preprod/
preview all use 2160; devnets typically override.
-}
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

{- | Parse all CLI flags into a 'DaemonConfig'. On
error, print usage to stderr and exit non-zero.
-}
parseConfig :: [String] -> IO DaemonConfig
parseConfig args0 = do
    (relay, args1) <- requireFlag "--relay-socket" args0
    (listen, args2) <- requireFlag "--listen" args1
    (magicS, args3) <- requireFlag "--network-magic" args2
    (slotsS, args4) <- requireFlag "--byron-epoch-slots" args3
    let (readyS, args5) =
            fromMaybe (show defaultReadyThreshold, args4) $
                takeFlag "--ready-threshold-slots" args4
        (kS, args6) =
            fromMaybe (show defaultSecurityParamK, args5) $
                takeFlag "--security-param-k" args5
        (mDbPath, args7) = case takeFlag "--db-path" args6 of
            Just (p, rest) -> (Just p, rest)
            Nothing -> (Nothing, args6)
    case args7 of
        [] -> pure ()
        extra -> dieUsage $ "Unexpected args: " <> show extra
    magic <- requireWord "--network-magic" magicS
    slots <- requireWord "--byron-epoch-slots" slotsS
    ready <- requireWord "--ready-threshold-slots" readyS
    k <- requireWord "--security-param-k" kS
    pure
        DaemonConfig
            { dcRelaySocket = relay
            , dcListenSocket = listen
            , dcNetworkMagic = fromIntegral (magic :: Word)
            , dcByronEpochSlots = fromIntegral (slots :: Word)
            , dcReadyThresholdSlots = fromIntegral (ready :: Word)
            , dcSecurityParamK = fromIntegral (k :: Word)
            , dcDbPath = mDbPath
            }
  where
    requireFlag key args =
        maybe
            (dieUsage $ "Missing required flag: " <> key)
            pure
            (takeFlag key args)
    requireWord key s =
        maybe
            (dieUsage $ key <> " expects a non-negative integer, got: " <> s)
            pure
            (readMaybe s)

-- | Print usage and exit 1.
dieUsage :: String -> IO a
dieUsage msg = do
    prog <- getProgName
    hPutStrLn stderr msg
    hPutStrLn stderr ""
    hPutStrLn stderr $ "Usage: " <> prog <> " \\"
    hPutStrLn stderr "  --relay-socket PATH \\"
    hPutStrLn stderr "  --listen PATH \\"
    hPutStrLn stderr "  --network-magic INT \\"
    hPutStrLn stderr "  --byron-epoch-slots INT \\"
    hPutStrLn stderr "  [--ready-threshold-slots INT] \\"
    hPutStrLn stderr "  [--security-param-k INT] \\"
    hPutStrLn stderr "  [--db-path PATH]"
    exitFailure

-- | Entry point. Parse args, log config, run the daemon.
main :: IO ()
main = do
    args <- getArgs
    cfg <- parseConfig args
    hPutStrLn stderr $ "utxo-indexer: " <> show cfg
    runDaemon cfg
