{- |
Module      : Main
Description : cardano-adversary daemon entry point
License     : Apache-2.0

CLI parsing only; everything else lives in
'Cardano.Node.Client.Adversary.Daemon.runDaemon'. CLI shape is
documented in @specs/036-cardano-adversary/spec.md@ and follows the
same idiom as @cardano-tx-generator@.

Required flags: @--control-socket@ and @--network-magic@.
Optional, repeatable: @--producer-host@. Optional:
@--producer-port@ (defaults to 3001).
-}
module Main (main) where

import Cardano.Node.Client.Adversary.Daemon (
    DaemonConfig (..),
    runDaemon,
 )
import Data.Word (Word32)
import Network.Socket (PortNumber)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

defaultProducerPort :: PortNumber
defaultProducerPort = 3001

{- | Parse the first @--key value@ pair from the argument list,
returning the value and the remaining args. Repeated flags are
handled separately by 'takeAllFlags'.
-}
takeFlag :: String -> [String] -> Maybe (String, [String])
takeFlag _ [] = Nothing
takeFlag key args = go [] args
  where
    go _ [] = Nothing
    go seen (k : v : rest)
        | k == key = Just (v, reverse seen ++ rest)
    go seen (x : rest) = go (x : seen) rest

{- | Pull every @--key value@ pair for the given key out of the
argument list, preserving order, and return the residual args.
-}
takeAllFlags :: String -> [String] -> ([String], [String])
takeAllFlags key = go [] []
  where
    go vs rest [] = (reverse vs, reverse rest)
    go vs rest (k : v : xs) | k == key = go (v : vs) rest xs
    go vs rest (x : xs) = go vs (x : rest) xs

parseConfig :: [String] -> IO DaemonConfig
parseConfig args0 = do
    (control, args1) <- requireFlag "--control-socket" args0
    (magicS, args2) <- requireFlag "--network-magic" args1
    let (hosts, args3) = takeAllFlags "--producer-host" args2
        (mPortS, args4) = case takeFlag "--producer-port" args3 of
            Just (p, rest) -> (Just p, rest)
            Nothing -> (Nothing, args3)
    case args4 of
        [] -> pure ()
        extra -> dieUsage $ "Unexpected args: " <> show extra
    magic <- requireWord32 "--network-magic" magicS
    port <- maybe (pure defaultProducerPort) (parsePort "--producer-port") mPortS
    pure
        DaemonConfig
            { daemonControlSocket = control
            , daemonProducerHosts = hosts
            , daemonProducerPort = port
            , daemonNetworkMagic = NetworkMagic magic
            }
  where
    requireFlag key args =
        maybe
            (dieUsage $ "Missing required flag: " <> key)
            pure
            (takeFlag key args)
    requireWord32 key s =
        maybe
            ( dieUsage $
                key
                    <> " expects a non-negative 32-bit integer, got: "
                    <> s
            )
            pure
            (readMaybe s :: Maybe Word32)
    parsePort key s =
        maybe
            ( dieUsage $
                key
                    <> " expects a port number 1..65535, got: "
                    <> s
            )
            pure
            (readMaybe s :: Maybe PortNumber)

dieUsage :: String -> IO a
dieUsage msg = do
    prog <- getProgName
    hPutStrLn stderr msg
    hPutStrLn stderr ""
    hPutStrLn stderr $ "Usage: " <> prog <> " \\"
    hPutStrLn stderr "  --control-socket PATH \\"
    hPutStrLn stderr "  --network-magic INT \\"
    hPutStrLn stderr "  [--producer-host HOST]... \\"
    hPutStrLn stderr "  [--producer-port INT]"
    exitFailure

main :: IO ()
main = do
    args <- getArgs
    case args of
        ["--help"] -> printHelp
        ["-h"] -> printHelp
        _ -> do
            cfg <- parseConfig args
            runDaemon cfg

printHelp :: IO ()
printHelp = do
    prog <- getProgName
    putStrLn $ prog <> " — cardano-adversary daemon (PR B scaffold)"
    putStrLn ""
    putStrLn "Listens on a UNIX SOCK_STREAM control socket and answers one"
    putStrLn "NDJSON request per connection per the wire spec at"
    putStrLn "specs/036-cardano-adversary/contracts/control-wire.md."
    putStrLn ""
    putStrLn "Flags:"
    putStrLn "  --control-socket PATH    Bind path for the control socket. Required."
    putStrLn "  --network-magic INT      Cardano network magic. Required."
    putStrLn "  --producer-host HOST     Producer hostname (repeatable, optional)."
    putStrLn "  --producer-port INT      N2N port (default 3001)."
    putStrLn "  --help, -h               Print this help and exit 0."
