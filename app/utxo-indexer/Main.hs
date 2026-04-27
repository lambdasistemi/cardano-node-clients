{- |
Module      : Main
Description : utxo-indexer daemon entrypoint
License     : Apache-2.0

Minimal address->UTxO indexer daemon. Follows the chain
via N2C ChainSync from one relay socket, maintains an
in-memory address->UTxO index, exposes two read primitives
(@utxos_at@, @await@) plus a @ready@ probe over a Unix
domain socket using newline-delimited JSON.

This Main is the scaffolding patch: parses CLI flags,
prints the resolved config, exits 0. Subsequent patches
wire the chain-sync follower, the STM index, and the
NDJSON server.
-}
module Main (main) where

import Data.Maybe (fromMaybe)
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure, exitSuccess)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

-- | Resolved daemon configuration, populated from CLI flags.
data Config = Config
    { cfgRelaySocket :: FilePath
    -- ^ Path to the Cardano relay's N2C Unix socket.
    , cfgListenSocket :: FilePath
    -- ^ Path the daemon will listen on.
    , cfgNetworkMagic :: Word
    -- ^ Network magic of the target network.
    , cfgByronEpochSlots :: Word
    -- ^ Byron epoch slot count (genesis configuration).
    , cfgReadyThresholdSlots :: Word
    -- ^ Maximum @slotsBehind@ for the daemon to report
    -- @ready=true@ on the @ready@ request.
    }
    deriving stock (Show)

-- | Default ready threshold (slots).
defaultReadyThreshold :: Word
defaultReadyThreshold = 60

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

{- | Parse all CLI flags into a 'Config'. On error,
print usage to stderr and exit non-zero.
-}
parseConfig :: [String] -> IO Config
parseConfig args0 = do
    (relay, args1) <- requireFlag "--relay-socket" args0
    (listen, args2) <- requireFlag "--listen" args1
    (magicS, args3) <- requireFlag "--network-magic" args2
    (slotsS, args4) <- requireFlag "--byron-epoch-slots" args3
    let (readyS, args5) =
            fromMaybe (show defaultReadyThreshold, args4) $
                takeFlag "--ready-threshold-slots" args4
    case args5 of
        [] -> pure ()
        extra -> dieUsage $ "Unexpected args: " <> show extra
    magic <- requireWord "--network-magic" magicS
    slots <- requireWord "--byron-epoch-slots" slotsS
    ready <- requireWord "--ready-threshold-slots" readyS
    pure
        Config
            { cfgRelaySocket = relay
            , cfgListenSocket = listen
            , cfgNetworkMagic = magic
            , cfgByronEpochSlots = slots
            , cfgReadyThresholdSlots = ready
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
    hPutStrLn stderr "  [--ready-threshold-slots INT]"
    exitFailure

-- | Entry point. Phase 0: parse args, log config, exit 0.
main :: IO ()
main = do
    args <- getArgs
    cfg <- parseConfig args
    putStrLn $ "utxo-indexer: " <> show cfg
    putStrLn "utxo-indexer: scaffolding only — chain-sync, index, and server land in subsequent patches"
    exitSuccess
