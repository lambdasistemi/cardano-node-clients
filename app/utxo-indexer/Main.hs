{- |
Module      : Main
Description : utxo-indexer daemon entrypoint
License     : Apache-2.0

Minimal address->UTxO indexer daemon. Follows the chain
via N2C ChainSync from one relay socket, maintains an
indexed view (in-memory or RocksDB-backed), exposes its
read primitives (@utxos_at@, @await@, @ready@,
@utxos_with_asset@) over a Unix domain socket using
newline-delimited JSON.

Wraps the chain-sync follower in an in-process reconnect
supervisor (see issue #97) — the daemon survives
upstream-relay restarts without exiting.

This @Main@ only prints the usage text; flags are read by
'Cardano.Node.Client.UTxOIndexer.Daemon.parseDaemonArgs' and
everything else lives in
'Cardano.Node.Client.UTxOIndexer.Daemon.runDaemon'.
-}
module Main (main) where

import Cardano.Node.Client.N2C.Trace (defaultStderrTracer)
import Cardano.Node.Client.UTxOIndexer.Daemon (
    parseDaemonArgs,
    runDaemon,
 )
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

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
    hPutStrLn stderr "  [--db-path PATH] \\"
    hPutStrLn stderr "  [--reconnect-initial-ms INT] \\"
    hPutStrLn stderr "  [--reconnect-max-ms INT] \\"
    hPutStrLn stderr "  [--reconnect-reset-threshold-ms INT] \\"
    hPutStrLn stderr "  [--node-ready-timeout-ms INT] \\"
    hPutStrLn stderr "  [--stale-after-seconds INT]"
    exitFailure

-- | Entry point. Parse args, log config, run the daemon.
main :: IO ()
main = do
    args <- getArgs
    cfg <- either dieUsage pure (parseDaemonArgs args)
    hPutStrLn stderr $ "utxo-indexer: " <> show cfg
    runDaemon defaultStderrTracer cfg
