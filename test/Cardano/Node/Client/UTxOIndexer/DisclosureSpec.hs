{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.DisclosureSpec
Description : Freshness and limits of an asset answer, every combination
License     : Apache-2.0

The freshness of an asset answer and its list of limits are pure
functions of the serving process's disclosure, one clock sample, one
readiness sample and the answer's own point. These properties walk
every combination the spec's rules distinguish:

* upstream connected or disconnected;
* time since the follower's last progress below, at, just above and far
  above the stale bound, and behind the clock (a clock step back);
* upstream tip unknown, behind the point, at the point, at the ready
  threshold, one slot past it, and far past it;

and check the status precedence (disconnected, then stale, then
catching up, then synced), the lag measured from the answer's own point
and nothing else, and the exact list of limits for every coverage.

The readiness fields the answer must not read — the readiness flag,
the processed slot and its lag — are generated independently of the
fields it must read, so a classification that consults them is caught.
-}
module Cardano.Node.Client.UTxOIndexer.DisclosureSpec (spec) where

import Cardano.Node.Client.N2C.Reconnect (
    DisconnectInfo (..),
    UpstreamStatus (..),
 )
import Cardano.Node.Client.UTxOIndexer.Disclosure (
    AddressCoverage (..),
    Coverage (..),
    CoverageStart (..),
    Disclosure (..),
    Freshness (..),
    FreshnessStatus (..),
    Limit (..),
    answerLimits,
    assessFreshness,
 )
import Cardano.Node.Client.UTxOIndexer.Server (ReadyStatus (..))
import Cardano.Node.Client.UTxOIndexer.Types (
    BlockHash (..),
    SlotNo (..),
 )
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Maybe (isNothing)
import Data.Text qualified as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (
    NominalDiffTime,
    UTCTime (..),
    addUTCTime,
    secondsToNominalDiffTime,
 )
import Data.Word (Word64)
import Test.Hspec (
    Spec,
    describe,
    expectationFailure,
    it,
    shouldBe,
 )
import Test.QuickCheck (
    Args (chatty, maxSuccess),
    Gen,
    Property,
    checkCoverage,
    choose,
    counterexample,
    cover,
    elements,
    forAll,
    isSuccess,
    oneof,
    output,
    quickCheckWithResult,
    stdArgs,
    (.&&.),
    (===),
 )

spec :: Spec
spec = describe "asset answer disclosure: freshness and limits" $ do
    describe "assessFreshness" $ do
        it "classifies every combination by the precedence disconnected, stale, catching_up, synced" $
            holds 2000 $
                forAll genCase $ \c ->
                    let fr = assessCase c
                        expected = expectedStatus c
                     in coverStatuses c $
                            counterexample (show c) $
                                frStatus fr === expected

        it "measures slotsBehind from the answer's own point, clamped at zero" $
            holds 1000 $
                forAll genCase $ \c ->
                    let fr = assessCase c
                     in counterexample (show c) $
                            frSlotsBehind fr === expectedBehind c
                                .&&. frTipSlot fr === (SlotNo <$> cTip c)

        it "reports whole seconds since the last progress, never negative" $
            holds 1000 $
                forAll genCase $ \c ->
                    counterexample (show c) $
                        frSecondsSinceProgress (assessCase c)
                            === expectedSeconds c

        it "ignores the readiness flag, the processed slot and its lag" $
            holds 500 $
                forAll genCase $ \c ->
                    forAll genNoise $ \noise ->
                        let quiet = assessCase c
                            noisy = assessCase c{cNoise = noise}
                         in counterexample (show (c, noise)) $
                                quiet === noisy

        it "changes slotsBehind with the point, not with the processed slot" $
            -- Two answers differing only in their point: the lag moves
            -- with the point by exactly the difference.
            forM_ [(100, 130), (130, 100)] $ \(p1, p2) -> do
                let base =
                        Case
                            { cUpstream = Nothing
                            , cAge = 0
                            , cTip = Just 200
                            , cPoint = p1
                            , cThreshold = 60
                            , cBound = 600
                            , cNoise = Noise False (Just 7) (Just 3)
                            }
                frSlotsBehind (assessCase base) `shouldBe` Just (200 - p1)
                frSlotsBehind (assessCase base{cPoint = p2})
                    `shouldBe` Just (200 - p2)

    describe "answerLimits" $ do
        it "lists exactly the limits that apply, in wire order, for every coverage and status" $
            forM_ coverages $ \cov ->
                forM_ allStatuses $ \st -> do
                    let fr =
                            Freshness
                                { frStatus = st
                                , frTipSlot = Just (SlotNo 10)
                                , frSlotsBehind = Just 0
                                , frSecondsSinceProgress = 1
                                }
                    answerLimits cov fr `shouldBe` expectedLimits cov st

        it "is empty only for full coverage from origin and a synced status" $ do
            let empties =
                    [ (cov, st)
                    | cov <- coverages
                    , st <- allStatuses
                    , null (answerLimits cov (freshnessOf st))
                    ]
            empties
                `shouldBe` [(Coverage FromOrigin AllAddresses, Synced)]
  where
    freshnessOf st =
        Freshness
            { frStatus = st
            , frTipSlot = Nothing
            , frSlotsBehind = Nothing
            , frSecondsSinceProgress = 0
            }

-- * The rules, as the spec states them

expectedStatus :: Case -> FreshnessStatus
expectedStatus c
    | Just _ <- cUpstream c = Disconnected
    | expectedSeconds c > cBound c = Stale
    | Nothing <- cTip c = CatchingUp
    | Just b <- expectedBehind c, b > cThreshold c = CatchingUp
    | otherwise = Synced

expectedBehind :: Case -> Maybe Word64
expectedBehind c = do
    tip <- cTip c
    pure (if tip > cPoint c then tip - cPoint c else 0)

expectedSeconds :: Case -> Word64
expectedSeconds c
    | cAge c <= 0 = 0
    | otherwise = floor (cAge c)

expectedLimits :: Coverage -> FreshnessStatus -> [Limit]
expectedLimits (Coverage start addresses) st =
    [AddressFilterLimit | addresses == FilteredAddresses]
        <> [PartialHistoryLimit | start /= FromOrigin]
        <> case st of
            Synced -> []
            CatchingUp -> [CatchingUpLimit]
            Disconnected -> [DisconnectedLimit]
            Stale -> [StaleLimit]

allStatuses :: [FreshnessStatus]
allStatuses = [Synced, CatchingUp, Disconnected, Stale]

coverages :: [Coverage]
coverages =
    [ Coverage start addresses
    | start <-
        [ FromOrigin
        , FromPoint (SlotNo 4_000) (BlockHash (BS.replicate 32 0xC3))
        ]
    , addresses <- [AllAddresses, FilteredAddresses]
    ]

-- * Cases

{- | One combination: upstream (a disconnect reason or connected), age
of the last progress in seconds relative to the clock sample, upstream
tip, the answer's point, the ready threshold and the stale bound, plus
the readiness fields the answer must ignore.
-}
data Case = Case
    { cUpstream :: Maybe Text.Text
    , cAge :: NominalDiffTime
    , cTip :: Maybe Word64
    , cPoint :: Word64
    , cThreshold :: Word64
    , cBound :: Word64
    , cNoise :: Noise
    }
    deriving stock (Show)

data Noise = Noise
    { nReady :: Bool
    , nProcessed :: Maybe Word64
    , nBehind :: Maybe Word64
    }
    deriving stock (Eq, Show)

assessCase :: Case -> Freshness
assessCase c =
    assessFreshness disclosure now ready (SlotNo (cPoint c))
  where
    disclosure =
        Disclosure
            { dsNetworkMagic = 42
            , dsCoverage = Coverage FromOrigin AllAddresses
            , dsReadyThresholdSlots = cThreshold c
            , dsStaleAfterSeconds = cBound c
            }
    ready =
        ReadyStatus
            { rsReady = nReady (cNoise c)
            , rsTipSlot = SlotNo <$> cTip c
            , rsProcessedSlot = SlotNo <$> nProcessed (cNoise c)
            , rsSlotsBehind = nBehind (cNoise c)
            , rsUpstream = maybe UpstreamConnected disconnectedBy (cUpstream c)
            , rsLastProgress = addUTCTime (negate (cAge c)) now
            }
    disconnectedBy reason =
        UpstreamDisconnected
            DisconnectInfo{diReason = reason, diAttempt = 2, diSinceMs = 1_500}

now :: UTCTime
now = UTCTime (fromGregorian 2026 10 1) 43_200

genCase :: Gen Case
genCase = do
    threshold <- elements [0, 1, 60, 2_160]
    bound <- elements [1, 30, 600]
    point <- choose (0, 1_000_000)
    upstream <- oneof [pure Nothing, Just <$> elements ["bearer-closed", "probe"]]
    age <-
        oneof
            [ secondsToNominalDiffTime . fromIntegral <$> choose (0, bound - 1)
            , pure (fromIntegral bound)
            , pure (fromIntegral bound + 0.5)
            , pure (fromIntegral bound + 1)
            , secondsToNominalDiffTime . fromIntegral <$> choose (bound + 1, bound * 50)
            , negate . secondsToNominalDiffTime . fromIntegral <$> choose (1 :: Int, 90)
            ]
    tip <-
        oneof
            [ pure Nothing
            , Just <$> choose (0, point)
            , pure (Just point)
            , pure (Just (point + threshold))
            , pure (Just (point + threshold + 1))
            , Just . (point +) <$> choose (threshold + 1, threshold + 100_000)
            ]
    Case upstream age tip point threshold bound <$> genNoise

genNoise :: Gen Noise
genNoise =
    Noise
        <$> elements [False, True]
        <*> oneof [pure Nothing, Just <$> choose (0, 2_000_000)]
        <*> oneof [pure Nothing, Just <$> choose (0, 2_000_000)]

{- | Every status, and the boundaries that separate them, must be
reached often enough to count.
-}
coverStatuses :: Case -> Property -> Property
coverStatuses c =
    cover 10 (expectedStatus c == Disconnected) "disconnected"
        . cover 10 (expectedStatus c == Stale) "stale"
        . cover 10 (expectedStatus c == CatchingUp) "catching_up"
        . cover 10 (expectedStatus c == Synced) "synced"
        . cover 1 (stale && caught && connected) "stale while also behind"
        . cover 1 (disconnectedC && stale) "disconnected while also stale"
        . cover 1 (cAge c == fromIntegral (cBound c) && connected) "age exactly at the bound"
        . cover 1 (cAge c < 0 && connected) "clock behind the last progress"
        . cover 1 (cTip c == Just (cPoint c + cThreshold c) && connected) "lag exactly at the threshold"
        . cover 1 (maybe False (< cPoint c) (cTip c)) "tip behind the point"
  where
    connected = isNothing (cUpstream c)
    disconnectedC = not connected
    stale = expectedSeconds c > cBound c
    caught = maybe True (> cThreshold c) (expectedBehind c)

holds :: Int -> Property -> IO ()
holds n prop = do
    result <-
        quickCheckWithResult
            stdArgs{maxSuccess = n, chatty = False}
            (checkCoverage prop)
    unless (isSuccess result) (expectationFailure (output result))
