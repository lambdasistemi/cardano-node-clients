{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.Devnet
Description : Cardano-node subprocess for E2E tests
License     : Apache-2.0
-}
module Cardano.Node.Client.E2E.Devnet (
    withCardanoNode,
    withRestartableCardanoNode,

    -- * Genesis key
    genesisSignKey,
    genesisAddr,

    -- * Constitutional committee keys
    ccColdSignKey,
    ccHotSignKey,
    ccColdKeyHash,
    ccHotCredential,

    -- * Runtime-registered harness pool key
    harnessPoolColdSignKey,
    harnessPoolKh,

    -- * Key generation
    mkSignKey,
    keyHashFromSignKey,
    enterpriseAddr,

    -- * Signing
    addKeyWitness,
) where

import Cardano.Crypto.DSIGN (
    Ed25519DSIGN,
    SignKeyDSIGN,
    deriveVerKeyDSIGN,
    genKeyDSIGN,
 )
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address (
    Addr (..),
 )
import Cardano.Ledger.Api (
    addrTxWitsL,
    txIdTx,
    witsTxL,
 )
import Cardano.Ledger.BaseTypes (
    Network (..),
 )
import Cardano.Ledger.Core (
    extractHash,
 )
import Cardano.Ledger.Credential (Credential (..), StakeReference (..))
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (..),
    VKey (..),
    WitVKey (..),
    asWitness,
    coerceKeyRole,
    hashKey,
    signedDSIGN,
 )
import Cardano.Ledger.TxIn (TxId (..))
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.N2C.Probe (
    defaultProbeConfig,
    waitForNodeReady,
 )
import Cardano.Node.Client.N2C.Trace (nullN2CTracer)
import Control.Concurrent (threadDelay)
import Control.Exception (
    bracket,
    onException,
 )
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (
    IORef,
    newIORef,
    readIORef,
    writeIORef,
 )
import Data.Set qualified as Set
import Data.Time.Clock (
    NominalDiffTime,
    UTCTime,
    addUTCTime,
    getCurrentTime,
 )
import Data.Time.Clock.POSIX (
    utcTimeToPOSIXSeconds,
 )
import Data.Time.Format (
    defaultTimeLocale,
    formatTime,
 )
import Lens.Micro ((%~), (&))
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Directory (
    copyFile,
    createDirectoryIfMissing,
    doesFileExist,
    getTemporaryDirectory,
    removePathForcibly,
 )
import System.FilePath ((</>))
import System.IO (
    BufferMode (..),
    Handle,
    IOMode (..),
    hClose,
    hSetBuffering,
    openFile,
 )
import System.Posix.Files (ownerReadMode, setFileMode)
import System.Process (
    CreateProcess (..),
    ProcessHandle,
    StdStream (..),
    createProcess,
    proc,
    terminateProcess,
    waitForProcess,
 )

{- | Run a @cardano-node@ subprocess using the
genesis files from @srcGenesis@. The callback
receives the node socket path and the system
start time (POSIX ms) used in the genesis.
The node and its temp directory are cleaned up
on exit.
-}
withCardanoNode ::
    FilePath ->
    (FilePath -> Integer -> IO a) ->
    IO a
withCardanoNode srcGenesis action =
    withRestartableCardanoNode srcGenesis $ \sock t _ ->
        action sock t

{- | Like 'withCardanoNode' but exposes a third argument:
a @restart :: IO ()@ action that terminates the running
cardano-node and spawns a new one against the same
database, socket path, and genesis. Used by the issue-97
reproducer to drive a relay-process restart against an
indexer running in the same process.
-}
withRestartableCardanoNode ::
    FilePath ->
    (FilePath -> Integer -> IO () -> IO a) ->
    IO a
withRestartableCardanoNode srcGenesis action = do
    now <- getCurrentTime
    let startTime = addUTCTime startOffset now
        startMs =
            floor (utcTimeToPOSIXSeconds startTime)
                * 1000
    tmpDir <- prepareTmpDir srcGenesis startTime
    let logPath = tmpDir </> "node.log"
        sock = tmpDir </> "node.sock"
        spawnNode = do
            logH <- openFile logPath AppendMode
            hSetBuffering logH LineBuffering
            ph <- launchNode tmpDir logH
            pure (ph, logH)
        cleanupNode (ph, logH) = do
            terminateProcess ph
            void (waitForProcess ph)
            hClose logH
    bracket
        ( do
            np <- spawnNode
            newIORef np
        )
        ( \npRef -> do
            np <- readIORef npRef
            cleanupNode np
            removePathForcibly tmpDir `onException` pure ()
        )
        $ \npRef -> do
            waitForSocket sock 300
            -- Block until cardano-node's LSQ server replies
            -- with a non-Origin tip — i.e. ChainDB has finished
            -- loading. Replaces the previous 1 s blind grace
            -- with a real readiness check.
            waitForNodeReady
                nullN2CTracer
                defaultProbeConfig
                devnetNetworkMagic
                sock
            let restart = restartNode npRef sock spawnNode cleanupNode
            action sock startMs restart
                `onException` dumpNodeLog logPath

restartNode ::
    IORef (ProcessHandle, Handle) ->
    FilePath ->
    IO (ProcessHandle, Handle) ->
    ((ProcessHandle, Handle) -> IO ()) ->
    IO ()
restartNode npRef sock spawnNode cleanupNode = do
    oldNp <- readIORef npRef
    cleanupNode oldNp
    removePathForcibly sock `onException` pure ()
    newNp <- spawnNode
    writeIORef npRef newNp
    waitForSocket sock 300
    -- Block until ChainDB has finished loading and the LSQ
    -- server is replying with a non-Origin tip. Replaces the
    -- previous fixed sleep — the new node is ready when it
    -- says it is.
    waitForNodeReady
        nullN2CTracer
        defaultProbeConfig
        devnetNetworkMagic
        sock

{- | The devnet's network magic, hardcoded in the
genesis files patched by 'prepareTmpDir'. Used by the
LSQ readiness probe.
-}
devnetNetworkMagic :: NetworkMagic
devnetNetworkMagic = NetworkMagic 42

{- | Prepare a temporary directory with patched
genesis files and delegate keys.
-}
prepareTmpDir ::
    FilePath -> UTCTime -> IO FilePath
prepareTmpDir srcGenesis startTime = do
    sysTmp <- getTemporaryDirectory
    let tmpDir = sysTmp </> "cardano-e2e"
    removePathForcibly tmpDir
    createDirectoryIfMissing True tmpDir
    createDirectoryIfMissing
        True
        (tmpDir </> "db")
    createDirectoryIfMissing
        True
        (tmpDir </> "delegate-keys")
    -- Copy genesis files
    let cp name =
            copyFile
                (srcGenesis </> name)
                (tmpDir </> name)
    cp "alonzo-genesis.json"
    cp "conway-genesis.json"
    cp "dijkstra-genesis.json"
    cp "node-config.json"
    cp "topology.json"
    -- Patch genesis start times
    patchShelleyGenesis startTime srcGenesis tmpDir
    patchByronGenesis startTime srcGenesis tmpDir
    -- Copy delegate keys and restrict permissions
    -- (cardano-node refuses keys with "other" bits)
    let srcKeys = srcGenesis </> "delegate-keys"
        dstKeys = tmpDir </> "delegate-keys"
        copyKey name = do
            copyFile
                (srcKeys </> name)
                (dstKeys </> name)
            setFileMode
                (dstKeys </> name)
                ownerReadMode
    copyKey "delegate1.kes.skey"
    copyKey "delegate1.vrf.skey"
    copyKey "delegate1.opcert"
    pure tmpDir

{- | Copy shelley-genesis.json, replacing
@PLACEHOLDER@ with the current UTC time.
-}
patchShelleyGenesis ::
    UTCTime -> FilePath -> FilePath -> IO ()
patchShelleyGenesis now srcDir dstDir = do
    let timeStr =
            BS8.pack $
                formatTime
                    defaultTimeLocale
                    "%Y-%m-%dT%H:%M:%SZ"
                    now
    content <-
        BS.readFile
            (srcDir </> "shelley-genesis.json")
    let patched =
            replaceSubstring
                "PLACEHOLDER"
                timeStr
                content
    BS.writeFile
        (dstDir </> "shelley-genesis.json")
        patched

{- | Copy byron-genesis.json, replacing
@\"startTime\": 0@ with the current UNIX time.
-}
patchByronGenesis ::
    UTCTime -> FilePath -> FilePath -> IO ()
patchByronGenesis now srcDir dstDir = do
    let epoch =
            BS8.pack $
                show
                    ( floor (utcTimeToPOSIXSeconds now) ::
                        Int
                    )
    content <-
        BS.readFile
            (srcDir </> "byron-genesis.json")
    let patched =
            replaceSubstring
                "\"startTime\": 0"
                ("\"startTime\": " <> epoch)
                content
    BS.writeFile
        (dstDir </> "byron-genesis.json")
        patched

{- | Replace the first occurrence of @needle@ in a
ByteString.
-}
replaceSubstring ::
    BS.ByteString ->
    BS.ByteString ->
    BS.ByteString ->
    BS.ByteString
replaceSubstring needle replacement content =
    let (before, after) =
            BS.breakSubstring needle content
     in if BS.null after
            then content
            else
                before
                    <> replacement
                    <> BS.drop
                        (BS.length needle)
                        after

-- | Launch @cardano-node run@ as a subprocess.
launchNode ::
    FilePath -> Handle -> IO ProcessHandle
launchNode tmpDir logH = do
    let keysDir = tmpDir </> "delegate-keys"
        args =
            [ "run"
            , "--config"
            , tmpDir </> "node-config.json"
            , "--topology"
            , tmpDir </> "topology.json"
            , "--database-path"
            , tmpDir </> "db"
            , "--socket-path"
            , tmpDir </> "node.sock"
            , "--shelley-kes-key"
            , keysDir </> "delegate1.kes.skey"
            , "--shelley-vrf-key"
            , keysDir </> "delegate1.vrf.skey"
            , "--shelley-operational-certificate"
            , keysDir </> "delegate1.opcert"
            ]
        cp =
            (proc "cardano-node" args)
                { std_out = UseHandle logH
                , std_err = UseHandle logH
                }
    (_, _, _, ph) <- createProcess cp
    pure ph

-- | Print the last 50 lines of the node log.
dumpNodeLog :: FilePath -> IO ()
dumpNodeLog logPath = do
    logContent <- BS.readFile logPath
    let allLines = BS8.lines logContent
        tailLines =
            drop
                (max 0 (length allLines - 50))
                allLines
    BS8.putStrLn
        ( BS8.unlines
            ( "=== Node log (last 50) ==="
                : tailLines
            )
        )

{- | How far in the future to set the genesis
@systemStart@. Gives the node time to
initialise before the first slot arrives.
-}
startOffset :: NominalDiffTime
startOffset = 5

{- | Poll for the socket file every 100ms,
up to @n@ attempts (30s at 300 attempts).
-}
waitForSocket :: FilePath -> Int -> IO ()
waitForSocket _ 0 =
    error
        "Timed out waiting for \
        \cardano-node socket"
waitForSocket path n = do
    exists <- doesFileExist path
    unless exists $ do
        threadDelay 100_000
        waitForSocket path (n - 1)

{- | Genesis UTxO signing key. Matches the address
in @shelley-genesis.json@ @initialFunds@.
Seed must be exactly 32 bytes.
-}
genesisSignKey :: SignKeyDSIGN Ed25519DSIGN
genesisSignKey =
    mkSignKey
        "e2e-genesis-utxo-key-seed-000001"

{- | Enterprise testnet address for the genesis
UTxO key.
-}
genesisAddr :: Addr
genesisAddr =
    enterpriseAddr
        (keyHashFromSignKey genesisSignKey)

{- | Stock constitutional-committee cold signing key.
Its key hash is the sole member of
@committee.members@ in @conway-genesis.json@.
Seed must be exactly 32 bytes.
-}
ccColdSignKey :: SignKeyDSIGN Ed25519DSIGN
ccColdSignKey =
    mkSignKey
        "e2e-cc-cold-key-seed-00000000001"

{- | Stock constitutional-committee hot signing key.
Authorized at runtime via a
@ConwayAuthCommitteeHotKey@ certificate witnessed
by 'ccColdSignKey'. Seed must be exactly 32 bytes.
-}
ccHotSignKey :: SignKeyDSIGN Ed25519DSIGN
ccHotSignKey =
    mkSignKey
        "e2e-cc-hot-key-seed-000000000001"

{- | Cold key hash of the stock committee member,
matching @committee.members@ in
@conway-genesis.json@.
-}
ccColdKeyHash :: KeyHash ColdCommitteeRole
ccColdKeyHash =
    coerceKeyRole (keyHashFromSignKey ccColdSignKey)

{- | Hot credential of the stock committee member,
for use in @ConwayAuthCommitteeHotKey@ and
@CommitteeVoter@.
-}
ccHotCredential :: Credential HotCommitteeRole
ccHotCredential =
    KeyHashObj
        (coerceKeyRole (keyHashFromSignKey ccHotSignKey))

{- | Cold signing key for a harness-controlled stake
pool registered at runtime (not the stock genesis
pool @e797e39f…@). Seed must be exactly 32 bytes.
-}
harnessPoolColdSignKey :: SignKeyDSIGN Ed25519DSIGN
harnessPoolColdSignKey =
    mkSignKey
        "e2e-harness-pool-cold-key-seed-01"

{- | Key hash of the runtime-registered harness
stake pool, for @RegPool@ / @DelegStakeVote@ /
@StakePoolVoter@.
-}
harnessPoolKh :: KeyHash StakePool
harnessPoolKh =
    coerceKeyRole (keyHashFromSignKey harnessPoolColdSignKey)

{- | Derive an Ed25519 signing key from a 32-byte
seed. The seed must be exactly 32 bytes.
-}
mkSignKey ::
    ByteString -> SignKeyDSIGN Ed25519DSIGN
mkSignKey seed =
    genKeyDSIGN (mkSeedFromBytes seed)

{- | Derive the payment key hash from a signing
key via 'VKey' + 'hashKey'.
-}
keyHashFromSignKey ::
    SignKeyDSIGN Ed25519DSIGN ->
    KeyHash Payment
keyHashFromSignKey sk =
    hashKey (VKey (deriveVerKeyDSIGN sk))

{- | Enterprise testnet address from a payment
key hash.
-}
enterpriseAddr :: KeyHash Payment -> Addr
enterpriseAddr kh =
    Addr Testnet (KeyHashObj kh) StakeRefNull

{- | Add a key witness to a transaction.
Construct 'WitVKey' from 'VKey' + 'SignedDSIGN',
then union into @witsTxL . addrTxWitsL@.
-}
addKeyWitness ::
    SignKeyDSIGN Ed25519DSIGN ->
    ConwayTx ->
    ConwayTx
addKeyWitness sk tx =
    tx & witsTxL . addrTxWitsL %~ Set.union wits
  where
    wits =
        Set.singleton (mkWitVKey (txIdTx tx) sk)

{- | Create a 'WitVKey' from a 'TxId' and signing
key.
-}
mkWitVKey ::
    TxId ->
    SignKeyDSIGN Ed25519DSIGN ->
    WitVKey Witness
mkWitVKey (TxId hash) sk =
    WitVKey
        (asWitness vk)
        (signedDSIGN sk (extractHash hash))
  where
    vk = VKey (deriveVerKeyDSIGN sk)
