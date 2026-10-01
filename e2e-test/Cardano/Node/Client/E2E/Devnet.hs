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

    -- * Restart with a hook while the node is down
    RestartableNode (..),
    withRestartableNode,

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
    throwIO,
    try,
    uninterruptibleMask_,
 )
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Foldable (traverse_)
import Data.IORef (
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
import GHC.Clock (getMonotonicTimeNSec)
import Lens.Micro ((%~), (&))
import Numeric (showHex)
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Directory (
    copyFile,
    createDirectory,
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
import System.IO.Error (isAlreadyExistsError)
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

Each run works in its own fresh directory
@cardano-e2e-\<hex\>@ under the system temporary
directory (@TMPDIR@ when set), so concurrent runs
on one host do not interfere. On every exit path
the node is terminated and then exactly that
directory is removed; nothing that existed before
the call is touched.
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

It is 'withRestartableNode' with a restart whose hook
does nothing.
-}
withRestartableCardanoNode ::
    FilePath ->
    (FilePath -> Integer -> IO () -> IO a) ->
    IO a
withRestartableCardanoNode srcGenesis action =
    withRestartableNode srcGenesis $ \node ->
        action
            (nodeSocket node)
            (nodeStartMs node)
            (restartNodeWith node (pure ()))

-- | A running devnet node, as handed out by 'withRestartableNode'.
data RestartableNode = RestartableNode
    { nodeSocket :: FilePath
    -- ^ the node socket path, the same across restarts
    , nodeStartMs :: Integer
    -- ^ the system start time (POSIX ms) used in the genesis
    , nodeRunDir :: FilePath
    -- ^ the run directory, removed when the bracket exits
    , nodeDbDir :: FilePath
    -- ^ the @--database-path@ of every spawn of the node,
    -- inside 'nodeRunDir'
    , restartNodeWith :: IO () -> IO ()
    -- ^ @restartNodeWith hook@ stops the node and waits for
    --     its process to exit, removes the socket path, runs
    --     @hook@, then spawns the node against the same run
    --     directory, database, socket and genesis and waits until
    --     it is ready.
    --
    --     While @hook@ runs no node process of the run exists and
    --     nothing accepts connections on the socket path, so the
    --     hook may change the database in 'nodeDbDir' (for
    --     instance restore a snapshot taken in an earlier hooked
    --     restart); the respawned node opens it as the hook left
    --     it. Readiness (a non-origin tip) is awaited without a
    --     time limit: an empty database never reaches it once the
    --     devnet is more than a few seconds old, and a restored
    --     one older than the forecast horizon (3 s on this devnet)
    --     is ready at its tip but may be unable to forge.
    --
    --     If @hook@ throws, the exception propagates, no node is
    --     spawned for that restart, and a later restart starts
    --     the node again.
    }

{- | Run a @cardano-node@ subprocess like 'withCardanoNode',
handing the callback a 'RestartableNode': the socket path,
the start time, the run and database directories, and a
restart that runs a hook while the node is down.

The bracket owns every node process it spawns: on every
exit path, including an exception thrown by a restart hook,
the current node (if any) is terminated and waited for,
then the run directory is removed. On a callback exception
the tail of the node log is printed first.
-}
withRestartableNode ::
    FilePath ->
    (RestartableNode -> IO a) ->
    IO a
withRestartableNode srcGenesis action = do
    now <- getCurrentTime
    let startTime = addUTCTime startOffset now
        startMs =
            floor (utcTimeToPOSIXSeconds startTime)
                * 1000
    -- The outer bracket owns the run directory, the inner one
    -- the node: the node is terminated before the directory is
    -- removed, and a failure while preparing the directory or
    -- spawning the node still removes it.
    bracket allocateRunDir removePathForcibly $ \tmpDir -> do
        prepareRunDir srcGenesis startTime tmpDir
        let logPath = tmpDir </> "node.log"
            sock = tmpDir </> "node.sock"
            spawnNode = do
                logH <- openFile logPath AppendMode
                hSetBuffering logH LineBuffering
                ph <- launchNode tmpDir logH `onException` hClose logH
                pure (ph, logH)
            -- The reference holds the node while one runs. A
            -- spawned node is recorded before anything can
            -- interrupt, and forgotten only once it has exited,
            -- so the release always reaches it.
            startNode npRef = do
                uninterruptibleMask_ $
                    spawnNode >>= writeIORef npRef . Just
                waitForSocket sock 300
                -- Block until cardano-node's LSQ server replies
                -- with a non-Origin tip — i.e. ChainDB has
                -- finished loading.
                waitForNodeReady
                    nullN2CTracer
                    defaultProbeConfig
                    devnetNetworkMagic
                    sock
            stopNode npRef =
                readIORef npRef
                    >>= traverse_
                        ( \(ph, logH) -> do
                            terminateProcess ph
                            void (waitForProcess ph)
                            hClose logH
                            writeIORef npRef Nothing
                        )
        bracket (newIORef Nothing) stopNode $ \npRef -> do
            startNode npRef
            let node =
                    RestartableNode
                        { nodeSocket = sock
                        , nodeStartMs = startMs
                        , nodeRunDir = tmpDir
                        , nodeDbDir = runDbDir tmpDir
                        , restartNodeWith = \hook -> do
                            stopNode npRef
                            removePathForcibly sock
                            hook
                            startNode npRef
                        }
            action node
                `onException` dumpNodeLog logPath

-- | The database directory of a run directory.
runDbDir :: FilePath -> FilePath
runDbDir tmpDir = tmpDir </> "db"

{- | The devnet's network magic, hardcoded in the
genesis files patched by 'prepareRunDir'. Used by the
LSQ readiness probe.
-}
devnetNetworkMagic :: NetworkMagic
devnetNetworkMagic = NetworkMagic 42

{- | Create a fresh run directory
@cardano-e2e-\<hex\>@ under 'getTemporaryDirectory'
(which honours @TMPDIR@). Creation is a single
@mkdir@, so an existing path is never reused: on a
name collision another suffix is tried.
-}
allocateRunDir :: IO FilePath
allocateRunDir = do
    sysTmp <- getTemporaryDirectory
    let attempt = do
            suffix <- getMonotonicTimeNSec
            let dir = sysTmp </> ("cardano-e2e-" <> showHex suffix "")
            created <- try (createDirectory dir)
            case created of
                Right () -> pure dir
                Left e
                    | isAlreadyExistsError e -> attempt
                    | otherwise -> throwIO e
    attempt

{- | Fill a freshly allocated run directory with
patched genesis files and delegate keys.
-}
prepareRunDir ::
    FilePath -> UTCTime -> FilePath -> IO ()
prepareRunDir srcGenesis startTime tmpDir = do
    createDirectory (runDbDir tmpDir)
    createDirectory (tmpDir </> "delegate-keys")
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
            , runDbDir tmpDir
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
