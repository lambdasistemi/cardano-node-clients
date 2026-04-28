{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.Persist
Description : On-disk persistence for the cardano-tx-generator daemon
License     : Apache-2.0

Two files inside the daemon's @--state-dir@:

* @master.seed@ — 32 raw bytes, written once at bootstrap,
  read-only thereafter. Sources the deterministic
  derivation in
  'Cardano.Node.Client.TxGenerator.Population'.

* @next-hd-index@ — UTF-8 decimal 'Word64' followed by a
  single newline. Atomically rewritten via tempfile +
  rename after every successful @transact@ or @refill@
  request. Returns 0 on cold start (file absent).

Atomic rewrite: write to @<path>.tmp@, flush, close,
@rename(2)@ to @<path>@. POSIX @rename(2)@ is atomic on
the same filesystem, so concurrent readers always observe
either the previous fully-written value or the new
fully-written value, never partial bytes.
-}
module Cardano.Node.Client.TxGenerator.Persist (
    -- * State directory layout
    masterSeedPath,
    nextHDIndexPath,

    -- * Master seed
    loadOrCreateSeed,

    -- * Next HD index
    readNextHDIndex,
    writeNextHDIndex,
) where

import Control.Exception (bracketOnError)
import Control.Monad (when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Word (Word64)
import System.Directory (
    createDirectoryIfMissing,
    doesFileExist,
    removeFile,
    renameFile,
 )
import System.FilePath (takeDirectory, (</>))
import System.IO (
    IOMode (WriteMode),
    hClose,
    hFlush,
    openBinaryFile,
 )
import System.Random qualified as Random

-- | Master-seed path within the state directory.
masterSeedPath :: FilePath -> FilePath
masterSeedPath stateDir = stateDir </> "master.seed"

-- | Next-HD-index path within the state directory.
nextHDIndexPath :: FilePath -> FilePath
nextHDIndexPath stateDir = stateDir </> "next-hd-index"

-- | Length of a master seed in bytes.
seedBytes :: Int
seedBytes = 32

{- | Load the master seed if it already exists at the
given path. Otherwise generate a fresh 32-byte seed
using the global 'StdGen' (system-entropy seeded), write
it atomically, and return it. The file is read-only
after this call from the daemon's perspective: nothing
else writes to it during a run.

Used at daemon startup. NOT on the per-request tx path —
the determinism contract for transact / refill (FR-002)
forbids ambient randomness there, and the seed for
those operations is always supplied by the caller.
-}
loadOrCreateSeed :: FilePath -> IO ByteString
loadOrCreateSeed path = do
    exists <- doesFileExist path
    if exists
        then BS.readFile path
        else do
            seed <-
                Random.getStdRandom
                    (Random.uniformByteString seedBytes)
            atomicWrite path seed
            pure seed

{- | Read the persisted next-HD-index. Returns 0 if the
file does not exist (cold start). Throws on a malformed
file (anything that's not @<decimal>@ optionally
followed by a single trailing newline).
-}
readNextHDIndex :: FilePath -> IO Word64
readNextHDIndex path = do
    exists <- doesFileExist path
    if exists
        then do
            bytes <- BS.readFile path
            case parseDecimal bytes of
                Just n -> pure n
                Nothing ->
                    fail $
                        "next-hd-index: malformed file at "
                            <> path
        else pure 0
  where
    parseDecimal :: ByteString -> Maybe Word64
    parseDecimal bs =
        let trimmed = BS.dropWhileEnd (== 0x0A) bs
         in case reads (BS8.unpack trimmed) of
                [(n, "")] -> Just n
                _ -> Nothing

{- | Atomically rewrite the next-HD-index file with the
given value. Creates the parent directory if missing.
Concurrent readers see either the old value or the new
value, never a partial write.
-}
writeNextHDIndex :: FilePath -> Word64 -> IO ()
writeNextHDIndex path n =
    atomicWrite path (BS8.pack (show n <> "\n"))

{- | Atomic write helper: write to @<path>.tmp@, flush,
close, then @rename@ the temp file over the destination.
Removes the temp file on failure to avoid stale files
accumulating. Creates the parent directory if it does
not exist.

Caveat: this does not call @fsync(2)@ on the file or its
parent directory, so a power loss between @write@ and a
flushed-to-disk @rename@ may leave the file with stale
contents. That is acceptable for the tx-generator's
recovery contract (SC-006): the indexer's chain-sync
state is the authoritative source for replay, and a
stale @next-hd-index@ at most causes a small replay
overlap, never data corruption.
-}
atomicWrite :: FilePath -> ByteString -> IO ()
atomicWrite path bytes = do
    createDirectoryIfMissing True (takeDirectory path)
    let tmp = path <> ".tmp"
    bracketOnError
        (openBinaryFile tmp WriteMode)
        ( \h -> do
            hClose h
            removeFileIfPresent tmp
        )
        ( \h -> do
            BS.hPut h bytes
            hFlush h
            hClose h
        )
    renameFile tmp path

removeFileIfPresent :: FilePath -> IO ()
removeFileIfPresent p = do
    exists <- doesFileExist p
    when exists (removeFile p)
