{- |
Module      : Cardano.Node.Client.UTxOIndexer.FaultCheckSpec
Description : The fault-check classifier on every result kind
License     : Apache-2.0

Drives 'runExample' through every outcome it has, on a fixture spec
whose examples pass, fail on an expectation, fail by an exception
(directly and from a joined thread), are pending, are duplicated or
are absent, and checks the outcome, its token and its exit code. No
outcome may exit 1, the code reserved for a faulted build that fails
in nix.
-}
module Cardano.Node.Client.UTxOIndexer.FaultCheckSpec (spec) where

import Cardano.Node.Client.UTxOIndexer.FaultCheck (
    Outcome (..),
    exitCodeOf,
    render,
    runExample,
 )
import Control.Concurrent.Async (async, wait)
import Control.Monad (forM_)
import System.Exit (ExitCode (..))
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    pendingWith,
    shouldBe,
    shouldNotBe,
 )

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer fault-check classifier" $
        forM_ cases $ \(example, outcome, token, code) ->
            it (example <> " is " <> token) $ do
                (got, _) <- runExample fixture example
                got `shouldBe` outcome
                render got `shouldBe` token
                exitCodeOf got `shouldBe` code
                exitCodeOf got `shouldNotBe` ExitFailure 1

-- | (example path, outcome, token, exit code)
cases :: [(String, Outcome, String, ExitCode)]
cases =
    [ ("fixture/passes", Survived, "SURVIVED", ExitFailure 3)
    , ("fixture/fails on shouldBe", Killed, "KILLED", ExitSuccess)
    , ("fixture/fails on a reason", Killed, "KILLED", ExitSuccess)
    , ("fixture/fails on shouldBe in a joined thread", Killed, "KILLED", ExitSuccess)
    , setup "fixture/fails by an exception" "failed-by-exception"
    , setup "fixture/fails by an exception in a joined thread" "failed-by-exception"
    , setup "fixture/is pending" "example-pending"
    , setup "fixture/twice" "example-not-unique"
    , setup "fixture/absent" "example-not-run"
    , setup "fixture" "example-not-run"
    ]
  where
    setup example reason =
        ( example
        , SetupFailure reason
        , "SETUP-FAILURE:" <> reason
        , ExitFailure 2
        )

fixture :: Spec
fixture = describe "fixture" $ do
    it "passes" (pure () :: IO ())
    it "fails on shouldBe" $ (1 :: Int) `shouldBe` 2
    it "fails on a reason" $ expectationFailure "reason"
    it "fails on shouldBe in a joined thread" $
        async ((1 :: Int) `shouldBe` 2) >>= wait
    it "fails by an exception" (error "boom" :: IO ())
    it "fails by an exception in a joined thread" $
        async (error "boom" :: IO ()) >>= wait
    it "is pending" $ pendingWith "later"
    it "twice" (pure () :: IO ())
    it "twice" (pure () :: IO ())
