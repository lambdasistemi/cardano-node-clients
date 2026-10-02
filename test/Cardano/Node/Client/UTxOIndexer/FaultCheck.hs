{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.FaultCheck
Description : Run one hspec example and classify its result
License     : Apache-2.0

The classifier behind the fault checks. 'runExample' runs exactly one
example of a spec, named by its full hspec path (@describe/…/it@), and
classifies the result:

* 'Killed' — the example ran and failed on an expectation;
* 'Survived' — the example ran and passed;
* 'SetupFailure' — the example did not run, ran more than once, was
  pending, or failed by an exception rather than an expectation.

'render' gives the outcome token the fault-check script reads and
'exitCodeOf' its exit code: 0, 3 and 2 respectively, never 1.
-}
module Cardano.Node.Client.UTxOIndexer.FaultCheck (
    Outcome (..),
    runExample,
    render,
    exitCodeOf,
) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (intercalate)
import System.Exit (ExitCode (..))
import Test.Hspec.Core.Format (
    Event (..),
    FailureReason (..),
    Item (..),
    Result (..),
 )
import Test.Hspec.Core.Runner (
    Config (..),
    defaultConfig,
    runSpec,
 )
import Test.Hspec.Core.Spec (Spec)

-- | One classified run of the named example.
data Outcome
    = Killed
    | Survived
    | SetupFailure String
    deriving stock (Eq, Show)

{- | Run the spec restricted to the example whose full path equals the
argument, and classify it. The second component is the failure
detail, empty when there is none.
-}
runExample :: Spec -> String -> IO (Outcome, String)
runExample spec example = do
    done <- newIORef []
    let record = \case
            ItemDone path item -> modifyIORef' done ((path, item) :)
            _ -> pure ()
        config =
            defaultConfig
                { configFilterPredicate =
                    Just (\path -> joinPath path == example)
                , configFormat = Just (\_ -> pure record)
                , configFailOnEmpty = False
                }
    _ <- runSpec spec config
    items <- readIORef done
    pure $ case items of
        [] -> (SetupFailure "example-not-run", "")
        [(_, Item{itemResult})] -> classify itemResult
        _ -> (SetupFailure "example-not-unique", "")

classify :: Result -> (Outcome, String)
classify = \case
    Success -> (Survived, "")
    Pending _ _ -> (SetupFailure "example-pending", "")
    Failure _ reason -> case reason of
        Error _ e ->
            (SetupFailure "failed-by-exception", "exception: " <> show e)
        NoReason -> (Killed, "")
        Reason r -> (Killed, r)
        ColorizedReason r -> (Killed, r)
        ExpectedButGot pre expected got ->
            ( Killed
            , intercalate
                "\n"
                ( maybe [] pure pre
                    <> ["expected: " <> expected, "but got:  " <> got]
                )
            )

joinPath :: ([String], String) -> String
joinPath (groups, item) = intercalate "/" (groups <> [item])

-- | The outcome token printed on stdout.
render :: Outcome -> String
render = \case
    Killed -> "KILLED"
    Survived -> "SURVIVED"
    SetupFailure reason -> "SETUP-FAILURE:" <> reason

-- | The runner's exit code for an outcome.
exitCodeOf :: Outcome -> ExitCode
exitCodeOf = \case
    Killed -> ExitSuccess
    Survived -> ExitFailure 3
    SetupFailure _ -> ExitFailure 2
