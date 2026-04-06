{-# LANGUAGE NumericUnderscores #-}

{- |
Module      : Cardano.Node.Client.E2E.CrashRecovery
Description : Generic crash recovery test harness
License     : Apache-2.0

Provides 'killDuring' — a generic function that starts
an application with an observable phase tracer, waits
for a target phase, and kills it. The harness is
parameterized over the phase type and knows nothing
about backends, databases, or specific applications.

The caller provides a bracket that receives a 'Tracer'
and a callback with the kill action. The harness kills
on the first event of the target phase and reports
which phases were observed.
-}
module Cardano.Node.Client.E2E.CrashRecovery (
    -- * Kill result
    KillResult (..),

    -- * Core primitive
    killDuring,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Concurrent.STM (
    atomically,
    newEmptyTMVarIO,
    readTMVar,
    tryPutTMVar,
 )
import Control.Monad (void, when)
import Control.Tracer (Tracer (..))
import Data.IORef (
    modifyIORef',
    newIORef,
    readIORef,
 )

-- | Result of killing an app during a target phase.
newtype KillResult phase = KillResult
    { phasesSeen :: [phase]
    -- ^ Unique phases observed, in order
    }
    deriving (Show)

{- | Start an app, observe phase transitions, kill
on the first event of the target phase. Returns
which phases were observed.

The start callback receives a 'Tracer' that must
be wired into the app's phase event pipeline.
-}
killDuring ::
    (Eq phase, Show phase) =>
    -- | Target phase to kill at
    phase ->
    {- | Bracket: receives tracer and a callback that
    receives the kill action. The bracket keeps
    resources alive until the callback returns.
    -}
    (Tracer IO phase -> (IO () -> IO ()) -> IO ()) ->
    -- | Kill result
    IO (KillResult phase)
killDuring targetPhase withApp = do
    seenRef <- newIORef ([] :: [phase])
    readyVar <- newEmptyTMVarIO

    let tracer = Tracer $ \phase -> do
            modifyIORef' seenRef $ \seen ->
                if phase `elem` seen
                    then seen
                    else seen ++ [phase]
            when (phase == targetPhase) $
                atomically $
                    void $
                        tryPutTMVar readyVar ()

    withApp tracer $ \killAction -> do
        -- Wait for target phase or timeout (60s)
        result <-
            race
                (threadDelay 60_000_000)
                (atomically $ readTMVar readyVar)

        killAction

        case result of
            Left () -> do
                phases <- readIORef seenRef
                error $
                    "killDuring: target phase "
                        ++ "never reached (saw: "
                        ++ show phases
                        ++ ")"
            Right () -> pure ()

    phases <- readIORef seenRef
    pure KillResult{phasesSeen = phases}
