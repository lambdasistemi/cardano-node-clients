{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.E2E.DevnetIsolationSpec
Description : Per-run working directory of the devnet brackets
License     : Apache-2.0

Every 'withCardanoNode' run owns a fresh directory under the
system temporary directory, removes exactly that directory on
every exit path once its node has stopped, and leaves every
path that existed before the call alone. Two runs live at the
same time in one process each reach their own node.

Each example points @TMPDIR@ at a fresh private root and
restores it afterwards, so nothing outside that root is
created, inspected or removed. The examples mutate
process-wide environment variables and therefore rely on hspec
running them sequentially.
-}
module Cardano.Node.Client.E2E.DevnetIsolationSpec (spec) where

import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup (devnetMagic, genesisDir)
import Cardano.Node.Client.N2C.Connection (
    newLSQChannel,
    newLTxSChannel,
    runNodeClient,
 )
import Cardano.Node.Client.N2C.LocalStateQuery (queryLSQ)
import Control.Concurrent.Async (concurrently, withAsync)
import Control.Concurrent.MVar (
    MVar,
    newEmptyMVar,
    putMVar,
    readMVar,
 )
import Control.Exception (
    Exception,
    IOException,
    bracket,
    throwIO,
    try,
 )
import Control.Monad (filterM, unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isDigit)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (sort, (\\))
import Ouroboros.Consensus.Ledger.Query (Query (GetChainPoint))
import System.Directory (
    createDirectory,
    doesDirectoryExist,
    listDirectory,
 )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath (
    equalFilePath,
    takeDirectory,
    takeFileName,
    (</>),
 )
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec (
    Expectation,
    Spec,
    around,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldThrow,
 )

spec :: Spec
spec =
    around withPrivateTmp $
        describe "devnet per-run working directory" $
            do
                it
                    "two live runs reach their own node from their own \
                    \directory"
                    concurrentRuns
                it
                    "sequential runs use distinct fresh directories and \
                    \remove them"
                    sequentialRuns
                it
                    "a pre-existing cardano-e2e directory is left \
                    \untouched"
                    legacyDirectoryUntouched
                it
                    "the directory is removed when the callback throws"
                    cleanupOnCallbackException
                it
                    "the directory is removed when the run is \
                    \interrupted before the node is ready"
                    cleanupOnInterrupt
                it
                    "the directory is removed when preparation fails"
                    cleanupOnPreparationFailure
                it
                    "the directory is removed when the node cannot be \
                    \spawned"
                    cleanupOnSpawnFailure

-- | Run an example with @TMPDIR@ pointed at a fresh root.
withPrivateTmp :: (FilePath -> IO ()) -> IO ()
withPrivateTmp action =
    withSystemTempDirectory "iso" $ \root ->
        withEnv "TMPDIR" root (action root)

-- | Set an environment variable for the duration of an action.
withEnv :: String -> String -> IO a -> IO a
withEnv name value action =
    bracket (lookupEnv name) restore $ \_ -> do
        setEnv name value
        action
  where
    restore = maybe (unsetEnv name) (setEnv name)

-- | What one run observed from inside its callback.
data Seen = Seen
    { seenDir :: FilePath
    -- ^ the run's working directory (parent of its socket)
    , seenGenesisKept :: Bool
    -- ^ its shelley genesis was unchanged while it ran
    }

concurrentRuns :: FilePath -> Expectation
concurrentRuns root = do
    gDir <- genesisDir
    aLive <- newEmptyMVar
    bLive <- newEmptyMVar
    beforeA <- listDirectory root
    result <-
        timeout 600_000_000 $
            concurrently
                ( withCardanoNode gDir $ \sock _ ->
                    observe aLive bLive sock
                )
                ( do
                    -- B enters only once A is live, so a
                    -- shared directory shows up as A's files
                    -- being replaced rather than as a setup
                    -- race between the two preparations.
                    readMVar aLive
                    beforeB <- listDirectory root
                    seen <- withCardanoNode gDir $ \sock _ ->
                        observe bLive aLive sock
                    pure (beforeB, seen)
                )
    case result of
        Nothing -> expectationFailure "concurrent runs timed out"
        Just (a, (beforeB, b)) -> do
            after <- listDirectory root
            violations
                ( [ "both runs were handed the working directory "
                    <> seenDir a
                  | seenDir a == seenDir b
                  ]
                    <> freshUnder root beforeA "run A" (seenDir a)
                    <> freshUnder root beforeB "run B" (seenDir b)
                    <> [ "run A's genesis in "
                        <> seenDir a
                        <> " was rewritten while A was live"
                       | not (seenGenesisKept a)
                       ]
                    <> [ "run B's genesis in "
                        <> seenDir b
                        <> " was rewritten while B was live"
                       | not (seenGenesisKept b)
                       ]
                    <> sameListing "after both runs" beforeA after
                )
  where
    observe :: MVar () -> MVar () -> FilePath -> IO Seen
    observe live other sock = do
        let dir = takeDirectory sock
            genesis = dir </> "shelley-genesis.json"
        genesisBefore <- BS.readFile genesis
        queryChainPoint sock
        putMVar live ()
        readMVar other
        queryChainPoint sock
        genesisAfter <- BS.readFile genesis
        pure
            Seen
                { seenDir = dir
                , seenGenesisKept = genesisBefore == genesisAfter
                }

sequentialRuns :: FilePath -> Expectation
sequentialRuns root = do
    gDir <- genesisDir
    before <- listDirectory root
    (dir1, during1) <- runOnce gDir
    middle <- listDirectory root
    (dir2, during2) <- runOnce gDir
    after <- listDirectory root
    after1 <- nodeProcesses dir1
    after2 <- nodeProcesses dir2
    violations
        ( [ "both runs were handed the working directory " <> dir1
          | dir1 == dir2
          ]
            <> freshUnder root before "run 1" dir1
            <> freshUnder root middle "run 2" dir2
            <> sameListing "after run 1" before middle
            <> sameListing "after run 2" before after
            <> ["no node process seen for " <> dir1 | null during1]
            <> ["no node process seen for " <> dir2 | null during2]
            <> ["node still running for " <> dir1 | not (null after1)]
            <> ["node still running for " <> dir2 | not (null after2)]
        )
  where
    runOnce gDir = withCardanoNode gDir $ \sock _ -> do
        queryChainPoint sock
        let dir = takeDirectory sock
        procs <- nodeProcesses dir
        pure (dir, procs)

legacyDirectoryUntouched :: FilePath -> Expectation
legacyDirectoryUntouched root = do
    gDir <- genesisDir
    let legacy = root </> "cardano-e2e"
        keep = legacy </> "keep"
        content = "owned by someone else"
    createDirectory legacy
    BS.writeFile keep content
    before <- listDirectory root
    dir <- withCardanoNode gDir $ \sock _ -> do
        queryChainPoint sock
        pure (takeDirectory sock)
    kept <- try (BS.readFile keep) :: IO (Either IOException BS.ByteString)
    after <- listDirectory root
    violations
        ( [ "the run used the pre-existing directory " <> legacy
          | equalFilePath dir legacy
          ]
            <> [ "pre-existing " <> keep <> " was removed or changed"
               | kept /= Right content
               ]
            <> sameListing "after the run" before after
        )

data Boom = Boom
    deriving stock (Show, Eq)

instance Exception Boom

cleanupOnCallbackException :: FilePath -> Expectation
cleanupOnCallbackException root = do
    gDir <- genesisDir
    before <- listDirectory root
    seenRef <- newIORef Nothing
    withCardanoNode
        gDir
        ( \sock _ -> do
            let dir = takeDirectory sock
            procs <- nodeProcesses dir
            writeIORef seenRef (Just (dir, procs))
            throwIO Boom
        )
        `shouldThrow` (== Boom)
    seen <- readIORef seenRef
    after <- listDirectory root
    case seen of
        Nothing -> expectationFailure "callback never ran"
        Just (dir, during) -> do
            left <- nodeProcesses dir
            violations
                ( sameListing "after the callback threw" before after
                    <> [ "no node process seen for " <> dir
                       | null during
                       ]
                    <> [ "node still running for " <> dir
                       | not (null left)
                       ]
                )

cleanupOnInterrupt :: FilePath -> Expectation
cleanupOnInterrupt root = do
    gDir <- genesisDir
    before <- listDirectory root
    -- Genesis starts 5 s in the future, so readiness cannot
    -- complete within 3 s: the interrupt lands while the node
    -- is starting.
    r <- timeout 3_000_000 $ withCardanoNode gDir $ \_ _ -> pure ()
    after <- listDirectory root
    left <- nodeProcesses root
    violations
        ( ["the run became ready before the interrupt" | r == Just ()]
            <> sameListing "after the interrupt" before after
            <> ["node still running under " <> root | not (null left)]
        )

cleanupOnPreparationFailure :: FilePath -> Expectation
cleanupOnPreparationFailure root = do
    let missing = root </> "no-such-genesis"
    before <- listDirectory root
    r <-
        try (withCardanoNode missing $ \_ _ -> pure ()) ::
            IO (Either IOException ())
    after <- listDirectory root
    violations
        ( ["the run succeeded without genesis files" | r == Right ()]
            <> sameListing "after preparation failed" before after
        )

cleanupOnSpawnFailure :: FilePath -> Expectation
cleanupOnSpawnFailure root = do
    gDir <- genesisDir
    let noNode = root </> "no-node"
    createDirectory noNode
    before <- listDirectory root
    r <-
        withEnv "PATH" noNode $
            try (withCardanoNode gDir $ \_ _ -> pure ()) ::
            IO (Either IOException ())
    after <- listDirectory root
    violations
        ( [ "the run succeeded without a cardano-node on PATH"
          | r == Right ()
          ]
            <> sameListing "after the spawn failed" before after
        )

{- | One LocalStateQuery round-trip on the given socket: the
node must answer a chain-point query within 60 s.
-}
queryChainPoint :: FilePath -> IO ()
queryChainPoint sock = do
    lsq <- newLSQChannel 16
    ltxs <- newLTxSChannel 16
    withAsync (runNodeClient devnetMagic sock lsq ltxs) $ \_ -> do
        r <- timeout 60_000_000 (queryLSQ lsq GetChainPoint)
        case r of
            Nothing ->
                expectationFailure $
                    "no chain-point reply on " <> sock
            Just _ -> pure ()

{- | Process ids whose command line mentions @path@. A devnet
node is launched with absolute paths under its working
directory, so this finds the node of a run by its directory.
-}
nodeProcesses :: FilePath -> IO [String]
nodeProcesses path = do
    pids <- filter (all isDigit) <$> listDirectory "/proc"
    filterM mentions pids
  where
    needle = BS8.pack path
    mentions pid = do
        r <-
            try (BS.readFile ("/proc" </> pid </> "cmdline")) ::
                IO (Either IOException BS.ByteString)
        pure $ case r of
            Left _ -> False
            Right cmd -> needle `BS.isInfixOf` cmd

{- | The run's directory sits directly under @root@ and its name
was not present in @listing@, taken just before the call.
-}
freshUnder :: FilePath -> [FilePath] -> String -> FilePath -> [String]
freshUnder root listing who dir =
    [ who
        <> "'s directory "
        <> dir
        <> " is not directly under "
        <> root
    | not (equalFilePath (takeDirectory dir) root)
    ]
        <> [ who <> "'s directory " <> dir <> " existed before its call"
           | takeFileName dir `elem` listing
           ]

-- | The temporary root holds exactly the entries it held before.
sameListing :: String -> [FilePath] -> [FilePath] -> [String]
sameListing when before after =
    [ "temporary root "
        <> when
        <> ": left behind "
        <> show (sort after \\ sort before)
        <> ", lost "
        <> show (sort before \\ sort after)
    | sort before /= sort after
    ]

-- | Fail with every violated invariant at once.
violations :: [String] -> Expectation
violations vs = do
    exists <- doesDirectoryExist "/proc"
    unless exists $
        expectationFailure "/proc is unavailable; process checks would be vacuous"
    vs `shouldBe` []
