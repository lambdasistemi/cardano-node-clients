module Main (main) where

import Cardano.Chain.Slotting (EpochSlots (..))
import Cardano.Node.Client.N2C.ChainSync
    ( Fetched (..)
    , runChainSyncN2C
    , mkChainSyncN2C
    )
import ChainFollower
    ( Follower (..)
    , Intersector (..)
    , ProgressOrRewind (..)
    )
import Control.Tracer (nullTracer)
import Data.IORef
    ( newIORef
    , readIORef
    , modifyIORef'
    )
import Data.Time.Clock
    ( getCurrentTime
    , diffUTCTime
    )
import Ouroboros.Network.Block (SlotNo (..))
import Ouroboros.Network.Block qualified as Network
import Ouroboros.Network.Magic (NetworkMagic (..))
import Ouroboros.Network.Point (WithOrigin (..))
import System.Environment (getArgs)
import System.IO (hFlush, stdout)
import Text.Printf (printf)

main :: IO ()
main = do
    args <- getArgs
    case args of
        [socketPath, magicStr] -> do
            let magic = NetworkMagic (read magicStr)
            runBench socketPath magic
        _ -> putStrLn
            "Usage: n2c-throughput SOCKET_PATH NETWORK_MAGIC"

runBench :: FilePath -> NetworkMagic -> IO ()
runBench socketPath magic = do
    countRef <- newIORef (0 :: Int)
    startRef <- newIORef =<< getCurrentTime
    lastReportRef <- newIORef (0 :: Int)

    let mkFollower = Follower
            { rollForward = \Fetched{} tipSlot -> do
                modifyIORef' countRef (+ 1)
                count <- readIORef countRef
                lastReport <- readIORef lastReportRef
                if count - lastReport >= 5000
                    then do
                        now <- getCurrentTime
                        start <- readIORef startRef
                        let elapsed = realToFrac
                                (diffUTCTime now start)
                                :: Double
                            bps = fromIntegral count / elapsed
                        printf
                            "blocks=%d elapsed=%.1fs blk/s=%.0f tip=%d\n"
                            count elapsed bps (unSlotNo tipSlot)
                        hFlush stdout
                        modifyIORef' lastReportRef (const count)
                    else pure ()
                pure mkFollower
            , rollBackward = \_ ->
                pure $ Progress mkFollower
            }

        intersector = Intersector
            { intersectFound = \_ -> pure mkFollower
            , intersectNotFound = pure (intersector, [])
            }

    putStrLn "Starting N2C chain sync throughput bench..."
    putStrLn $ "Socket: " ++ socketPath
    putStrLn $ "Magic: " ++ show magic
    hFlush stdout

    result <- runChainSyncN2C
        (EpochSlots 21600)
        magic
        socketPath
        (mkChainSyncN2C
            nullTracer
            nullTracer
            intersector
            [Network.Point Origin]
        )
    case result of
        Left err -> putStrLn $ "Error: " ++ show err
        Right () -> putStrLn "Done."
