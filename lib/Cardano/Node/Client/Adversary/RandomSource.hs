{- |
Module      : Cardano.Node.Client.Adversary.RandomSource
Description : Steerable random source for the cardano-adversary daemon
License     : Apache-2.0

Every adversarial decision draws from this typeclass so the
Antithesis hypervisor can bias them. The default implementation
shells out to the @antithesis_random@ CLI when present on
@PATH@ and falls back to 'System.Random' for local development
when it is not.

A pure @splitFromSeed@ helper turns the per-request @seed@ field
of an NDJSON request into a 'StdGen'; the daemon uses that to
derive any further random values it needs without going back to
@antithesis_random@.
-}
module Cardano.Node.Client.Adversary.RandomSource (
    -- * Typeclass
    RandomSource (..),

    -- * Antithesis-aware default
    Antithesis,
    runAntithesis,

    -- * Pure helpers
    splitFromSeed,
) where

import Control.Exception (IOException, try)
import Data.Word (Word64)
import System.Directory (findExecutable)
import System.Process (readProcess)
import System.Random (StdGen, mkStdGen, randomIO)
import Text.Read (readMaybe)

-- | Source of randomness for adversarial decisions.
class (Monad m) => RandomSource m where
    -- | Draw an unsigned 64-bit integer.
    randomU64 :: m Word64

-- | Default implementation: hypervisor-aware in CI, host-RNG locally.
newtype Antithesis a = Antithesis {runAntithesis :: IO a}
    deriving newtype (Functor, Applicative, Monad)

instance RandomSource Antithesis where
    randomU64 = Antithesis $ do
        -- The antithesis_random CLI is shipped by the
        -- Antithesis runtime; if absent we are running
        -- locally and must fall back to host entropy.
        haveCli <- findExecutable "antithesis_random"
        case haveCli of
            Just _ -> readAntithesis
            Nothing -> randomIO
    {-# INLINE randomU64 #-}

{- | Read one decimal uint64 from the @antithesis_random@ CLI.
Falls back to 'randomIO' if the process fails to start or
returns garbage. The fallback keeps PR-B-quality smoke testing
working on a workstation where the runtime CLI is missing.
-}
readAntithesis :: IO Word64
readAntithesis = do
    result <- try @IOException (readProcess "antithesis_random" [] "")
    case result of
        Left _ -> randomIO
        Right out -> maybe randomIO pure (readMaybe (trim out))
  where
    trim = dropWhile (== ' ') . reverse . dropWhile isWhitespace . reverse
    isWhitespace c = c == ' ' || c == '\n' || c == '\r' || c == '\t'

{- | Derive a deterministic 'StdGen' from the @seed@ field of a
request. The daemon uses this to make a request reproducible
given the seed it received: any further randomness the request
needs is drawn from the returned generator, not from
@antithesis_random@. This matches the tx-generator's discipline
(single seed in → deterministic transaction body out).
-}
splitFromSeed :: Word64 -> StdGen
splitFromSeed = mkStdGen . fromIntegral
