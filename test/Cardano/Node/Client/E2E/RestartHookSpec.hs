{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.RestartHookSpec
Description : Hooked restart of the restartable devnet node
License     : Apache-2.0

'withRestartableNode' hands its callback a 'RestartableNode' whose
'restartNodeWith' stops the node, runs a caller hook while the node
is down, and spawns it again on the same run directory.

The node of a run is identified in the process table by its run
directory, which every argument of its command line is under; no
process outside the run is inspected or signalled.
-}
module Cardano.Node.Client.E2E.RestartHookSpec (spec) where

import Cardano.Node.Client.E2E.Devnet (
    RestartableNode (..),
    withRestartableNode,
 )
import Cardano.Node.Client.E2E.Setup (devnetMagic, genesisDir)
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.LocalStateQuery (queryLSQ)
import Cardano.Node.Client.Types (Block)
import Cardano.Slotting.Block (BlockNo (..))
import Cardano.Slotting.Slot (WithOrigin (..))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, tryReadMVar)
import Control.Exception (
    Exception,
    IOException,
    bracket,
    throwIO,
    try,
 )
import Control.Monad (filterM, forever, unless, void, (>=>))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isDigit)
import Data.Foldable (for_, traverse_)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Traversable (for)
import Data.Word (Word64)
import Network.Socket (
    Family (AF_UNIX),
    SockAddr (SockAddrUnix),
    SocketType (Stream),
    close,
    connect,
    defaultProtocol,
    socket,
 )
import Ouroboros.Consensus.Ledger.Query (
    Query (GetChainBlockNo, GetChainPoint),
 )
import System.Directory (
    copyFile,
    createDirectory,
    doesDirectoryExist,
    doesPathExist,
    listDirectory,
    removePathForcibly,
 )
import System.FilePath (
    addTrailingPathSeparator,
    equalFilePath,
    takeDirectory,
    (</>),
 )
import System.Timeout (timeout)
import Test.Hspec (
    Expectation,
    Spec,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldThrow,
 )

spec :: Spec
spec =
    describe "devnet hooked restart" $ do
        it
            "the node of the run is down and refuses connections \
            \while the hook runs"
            nodeDownDuringHook
        it
            "a database snapshot restored in the hook is what the \
            \respawned node opens"
            restoredSnapshotReopened
        it
            "a do-nothing hook leaves the respawned node on its \
            \chain"
            unchangedDatabaseKept
        it
            "a throwing hook leaves no node of the run and no run \
            \directory once the bracket exits"
            throwingHookNoOrphan
        it
            "after a throwing hook no node runs and a later restart \
            \starts it again"
            throwingHookThenRestart

-- | What the process table and the socket say about a run's node.
data Observed = Observed
    { obsPids :: [String]
    -- ^ live processes whose command line mentions the run directory
    , obsDbPaths :: [FilePath]
    -- ^ their @--database-path@ arguments
    , obsAccepts :: Bool
    -- ^ a connection to the socket path succeeded
    , obsSocketPresent :: Bool
    -- ^ something exists at the socket path
    }
    deriving stock (Show)

observe :: RestartableNode -> IO Observed
observe node = do
    pids <- nodeProcesses (nodeRunDir node)
    dbs <- concat <$> traverse databasePaths pids
    accepts <- socketAccepts (nodeSocket node)
    present <- doesPathExist (nodeSocket node)
    pure
        Observed
            { obsPids = pids
            , obsDbPaths = dbs
            , obsAccepts = accepts
            , obsSocketPresent = present
            }

-- INV-1 (down) and INV-5 (paths).
nodeDownDuringHook :: Expectation
nodeDownDuringHook = do
    gDir <- genesisDir
    withRestartableNode gDir $ \node -> do
        before <- observe node
        duringRef <- newIORef Nothing
        restartNodeWith node $
            observe node >>= writeIORef duringRef . Just
        mDuring <- readIORef duringRef
        after <- observe node
        queryChainPoint (nodeSocket node)
        case mDuring of
            Nothing -> expectationFailure "the hook never ran"
            Just during ->
                violations
                    ( alive "before the restart" before
                        <> [ "during the hook the run's node is alive: "
                            <> show (obsPids during)
                           | not (null (obsPids during))
                           ]
                        <> [ "during the hook the socket "
                            <> nodeSocket node
                            <> " accepts connections"
                           | obsAccepts during
                           ]
                        <> [ "during the hook the socket path "
                            <> nodeSocket node
                            <> " exists"
                           | obsSocketPresent during
                           ]
                        <> alive "after the restart" after
                        <> dbPathOf node "before the restart" before
                        <> dbPathOf node "after the restart" after
                        <> [ "database directory "
                            <> nodeDbDir node
                            <> " is not inside run directory "
                            <> nodeRunDir node
                           | not
                                ( equalFilePath
                                    (takeDirectory (nodeDbDir node))
                                    (nodeRunDir node)
                                )
                           ]
                    )
  where
    alive when o =
        [ "no live node of the run " <> when <> " (positive control)"
        | null (obsPids o)
        ]
            <> [ "socket does not accept " <> when <> " (positive control)"
               | not (obsAccepts o)
               ]
            <> [ "socket path absent " <> when <> " (positive control)"
               | not (obsSocketPresent o)
               ]
    dbPathOf node when o =
        [ "node "
            <> when
            <> " opens "
            <> show (obsDbPaths o)
            <> ", not "
            <> nodeDbDir node
        | not (all (equalFilePath (nodeDbDir node)) (obsDbPaths o))
            || null (obsDbPaths o)
        ]

-- INV-2 (mutation). A first hooked restart snapshots the database
-- while the node is down; once the chain has grown past the
-- snapshot, a second hooked restart puts the snapshot back.
restoredSnapshotReopened :: Expectation
restoredSnapshotReopened = do
    gDir <- genesisDir
    withRestartableNode gDir $ \node -> do
        (before, after) <- rewind node $ restoreSnapshot node
        unless (after < before) $
            expectationFailure $
                "respawned node tip is block "
                    <> show after
                    <> ", not below block "
                    <> show before
                    <> " seen before the stop: it did not open the \
                       \snapshot the hook restored"

-- Positive control for INV-2: the same observation with a do-nothing
-- second hook sees the chain carried over.
unchangedDatabaseKept :: Expectation
unchangedDatabaseKept = do
    gDir <- genesisDir
    withRestartableNode gDir $ \node -> do
        (before, after) <- rewind node (pure ())
        unless (after >= before) $
            expectationFailure $
                "respawned node tip is block "
                    <> show after
                    <> ", below block "
                    <> show before
                    <> " seen before the stop although the hook did \
                       \nothing"

{- | Snapshot the database in a hooked restart, let the chain grow
'chainGrowth' blocks past it, then restart with @hook@. Returns the
tip seen just before that restart and the tip of the respawned node.
-}
rewind :: RestartableNode -> IO () -> IO (Word64, Word64)
rewind node hook = do
    let sock = nodeSocket node
    _ <- tipAtLeast sock chainGrowth
    restartNodeWith node $
        copyTree (nodeDbDir node) (snapshotDir node)
    snapshotted <- chainBlockNo sock
    before <- tipAtLeast sock (snapshotted + chainGrowth)
    restartNodeWith node hook
    after <- chainBlockNo sock
    pure (before, after)

-- | Replace the node's database with the snapshot.
restoreSnapshot :: RestartableNode -> IO ()
restoreSnapshot node = do
    removePathForcibly (nodeDbDir node)
    copyTree (snapshotDir node) (nodeDbDir node)

-- | Where the snapshot lives: inside the run, removed with it.
snapshotDir :: RestartableNode -> FilePath
snapshotDir node = nodeRunDir node </> "db-snapshot"

-- | Copy a directory tree.
copyTree :: FilePath -> FilePath -> IO ()
copyTree from to = do
    createDirectory to
    entries <- listDirectory from
    for_ entries $ \e -> do
        isDir <- doesDirectoryExist (from </> e)
        if isDir
            then copyTree (from </> e) (to </> e)
            else copyFile (from </> e) (to </> e)

data Boom = Boom
    deriving stock (Show, Eq)

instance Exception Boom

-- INV-3 (no orphan).
throwingHookNoOrphan :: Expectation
throwingHookNoOrphan = do
    gDir <- genesisDir
    runDirVar <- newEmptyMVar
    seenRef <- newIORef Map.empty
    -- Every node process of the run is recorded, with its start
    -- time, from the moment the run directory is known until after
    -- the bracket has exited.
    let sample =
            tryReadMVar runDirVar
                >>= traverse_
                    ( nodeIdentities
                        >=> modifyIORef' seenRef . Map.union
                    )
        sampler = forever $ sample >> threadDelay 50_000
    withAsync sampler $ \_ ->
        withRestartableNode
            gDir
            ( \node -> do
                putMVar runDirVar (nodeRunDir node)
                -- Record the running node before the restart stops it.
                sample
                -- The hook works for a while before it throws, so a
                -- node wrongly spawned around it is recorded.
                restartNodeWith node $
                    threadDelay 3_000_000 >> throwIO Boom
            )
            `shouldThrow` (== Boom)
    seen <- readIORef seenRef
    mRunDir <- tryReadMVar runDirVar
    case mRunDir of
        Nothing -> expectationFailure "the callback never ran"
        Just runDir -> do
            left <- unreaped seen
            dirLeft <- doesDirectoryExist runDir
            violations
                ( [ "no node process of the run was ever seen \
                    \(positive control)"
                  | Map.null seen
                  ]
                    <> [ "node processes of the run were not reaped by \
                         \the bracket (pid, state): "
                        <> show left
                       | not (null left)
                       ]
                    <> [ "run directory " <> runDir <> " still exists"
                       | dirLeft
                       ]
                )

-- FR-4: no node is spawned for a restart whose hook throws, and the
-- bracket can still restart the node afterwards.
throwingHookThenRestart :: Expectation
throwingHookThenRestart = do
    gDir <- genesisDir
    withRestartableNode gDir $ \node -> do
        r <- try (restartNodeWith node (throwIO Boom))
        stopped <- observe node
        restartNodeWith node (pure ())
        restarted <- observe node
        queryChainPoint (nodeSocket node)
        violations
            ( [ "the restart returned " <> show r <> ", not Boom"
              | r /= Left Boom
              ]
                <> [ "a node of the run was spawned for the throwing \
                     \restart: "
                    <> show (obsPids stopped)
                   | not (null (obsPids stopped))
                   ]
                <> [ "the socket accepts after the throwing restart"
                   | obsAccepts stopped
                   ]
                <> [ "no node of the run after the later restart"
                   | null (obsPids restarted)
                   ]
            )

-- | Blocks the chain grows before each restart of the INV-2 examples.
chainGrowth :: Word64
chainGrowth = 20

-- | Wait until the tip reaches @n@ blocks and return it.
tipAtLeast :: FilePath -> Word64 -> IO Word64
tipAtLeast sock n = go (120 :: Int)
  where
    go 0 = fail $ "the chain did not reach " <> show n <> " blocks"
    go k = do
        b <- chainBlockNo sock
        if b >= n
            then pure b
            else threadDelay 500_000 >> go (k - 1)

-- | The node-reported tip block number (0 at origin).
chainBlockNo :: FilePath -> IO Word64
chainBlockNo sock = do
    r <- withLSQ sock GetChainBlockNo
    pure $ case r of
        Origin -> 0
        At (BlockNo b) -> b

{- | One LocalStateQuery round-trip on the given socket: the
node must answer a chain-point query within 60 s.
-}
queryChainPoint :: FilePath -> IO ()
queryChainPoint sock = void $ withLSQ sock GetChainPoint

withLSQ :: FilePath -> Query Block r -> IO r
withLSQ sock query = do
    lsq <- newLSQChannel 16
    ltxs <- newLTxSChannel 16
    withAsync (runNodeClient devnetMagic sock lsq ltxs) $ \_ -> do
        r <- timeout 60_000_000 (queryLSQ lsq query)
        case r of
            Nothing -> fail $ "no LocalStateQuery reply on " <> sock
            Just a -> pure a

-- | Whether a stream connection to the socket path succeeds.
socketAccepts :: FilePath -> IO Bool
socketAccepts path = do
    r <-
        try $
            bracket (socket AF_UNIX Stream defaultProtocol) close $
                \s -> connect s (SockAddrUnix path)
    pure $ case r of
        Left (_ :: IOException) -> False
        Right () -> True

{- | Process ids whose command line mentions @path@. A devnet
node is launched with absolute paths under its run directory,
so this finds the node of a run by its directory.
-}
nodeProcesses :: FilePath -> IO [String]
nodeProcesses path = do
    pids <- filter (all isDigit) <$> listDirectory "/proc"
    filterM mentions pids
  where
    needle = BS8.pack (addTrailingPathSeparator path)
    mentions pid = do
        r <- commandLine pid
        pure $ case r of
            Nothing -> False
            Just args -> any (needle `BS.isInfixOf`) args

-- | The @--database-path@ arguments of a process.
databasePaths :: String -> IO [FilePath]
databasePaths pid = do
    r <- commandLine pid
    pure $ case r of
        Nothing -> []
        Just args ->
            [ BS8.unpack v
            | (k, v) <- zip args (drop 1 args)
            , k == "--database-path"
            ]

commandLine :: String -> IO (Maybe [BS.ByteString])
commandLine pid = do
    r <-
        try (BS.readFile ("/proc" </> pid </> "cmdline")) ::
            IO (Either IOException BS.ByteString)
    pure $ either (const Nothing) (Just . BS.split 0) r

-- | Fail with every violated invariant at once.
violations :: [String] -> Expectation
violations vs = do
    exists <- doesDirectoryExist "/proc"
    unless exists $
        expectationFailure
            "/proc is unavailable; process checks would be vacuous"
    vs `shouldBe` []

{- | The node processes of a run, by pid, with their start time
(field 22 of @\/proc\/\<pid\>\/stat@), so a recorded pid is not
confused with a later process reusing it.
-}
nodeIdentities :: FilePath -> IO (Map.Map String BS.ByteString)
nodeIdentities runDir = do
    pids <- nodeProcesses runDir
    Map.fromList . catMaybes
        <$> traverse (\p -> fmap ((,) p . snd) <$> procStat p) pids

{- | The recorded processes that still exist, alive or as an
unreaped zombie, with their state letter.
-}
unreaped :: Map.Map String BS.ByteString -> IO [(String, String)]
unreaped seen =
    fmap catMaybes $
        for (Map.toList seen) $ \(pid, start) -> do
            r <- procStat pid
            pure $ case r of
                Just (state, start')
                    | start' == start -> Just (pid, BS8.unpack state)
                _ -> Nothing

-- | State letter and start time of a process, if it exists.
procStat :: String -> IO (Maybe (BS.ByteString, BS.ByteString))
procStat pid = do
    r <-
        try (BS.readFile ("/proc" </> pid </> "stat")) ::
            IO (Either IOException BS.ByteString)
    pure $ case r of
        Left _ -> Nothing
        Right stat ->
            -- Fields after the parenthesised command name start at
            -- field 3 (state); the start time is field 22.
            case BS8.words (snd (BS8.breakEnd (== ')') stat)) of
                fields@(state : _)
                    | length fields > 19 -> Just (state, fields !! 19)
                _ -> Nothing
