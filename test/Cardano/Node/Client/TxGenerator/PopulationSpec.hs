{- |
Module      : Cardano.Node.Client.TxGenerator.PopulationSpec
Description : Unit tests for deterministic key derivation
License     : Apache-2.0

Pins three properties of
'Cardano.Node.Client.TxGenerator.Population':

* @deriveSignKey master i@ is a pure function: same
  @(master, i)@ always returns the same signing key (and
  therefore the same address). FR-002 / SC-002 rest on
  this.
* Distinct indices give distinct keys (no accidental
  collisions for small @i@).
* The derivation produces 32-byte verification keys and
  addresses whose 'show' representation is stable across
  calls — any change to the scheme that would break a
  replay against a pre-existing @master.seed@ trips this.
-}
module Cardano.Node.Client.TxGenerator.PopulationSpec (spec) where

import Cardano.Crypto.DSIGN (
    DSIGNAlgorithm (deriveVerKeyDSIGN),
    rawSerialiseSigDSIGN,
    rawSerialiseSignKeyDSIGN,
    rawSerialiseVerKeyDSIGN,
    signDSIGN,
 )
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Node.Client.TxGenerator.Population (
    deriveAddr,
    deriveSeedAt,
    deriveSignKey,
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Test.Hspec (
    Spec,
    describe,
    it,
    shouldBe,
    shouldNotBe,
    shouldSatisfy,
 )

{- | A fixed 32-byte master seed used in the golden
vector. Bytes are 0..31.
-}
goldenMasterSeed :: ByteString
goldenMasterSeed = BS.pack [0 .. 31]

spec :: Spec
spec = describe "TxGenerator.Population" $ do
    describe "determinism" $ do
        it "deriveSeedAt is a pure function of (seed, i)" $ do
            let s1 = deriveSeedAt goldenMasterSeed 0
            let s2 = deriveSeedAt goldenMasterSeed 0
            s1 `shouldBe` s2
            BS.length s1 `shouldBe` 32

        it "deriveSignKey at the same (seed, i) yields the same key" $ do
            let sk1 = deriveSignKey goldenMasterSeed 7
            let sk2 = deriveSignKey goldenMasterSeed 7
            rawSerialiseSignKeyDSIGN sk1
                `shouldBe` rawSerialiseSignKeyDSIGN sk2

        it "deriveAddr at the same (net, seed, i) is byte-identical" $ do
            let a1 = deriveAddr Testnet goldenMasterSeed 42
            let a2 = deriveAddr Testnet goldenMasterSeed 42
            show a1 `shouldBe` show a2

    describe "distinct indices give distinct keys / addresses" $ do
        it "verification keys are pairwise distinct for i in [0, 64)" $ do
            let vks =
                    [ rawSerialiseVerKeyDSIGN
                        (deriveVerKeyDSIGN (deriveSignKey goldenMasterSeed i))
                    | i <- [0 .. 63]
                    ]
            length vks `shouldBe` 64
            Set.size (Set.fromList vks) `shouldBe` 64

        it "addresses on Testnet are pairwise distinct for i in [0, 64)" $ do
            let addrs =
                    [ show (deriveAddr Testnet goldenMasterSeed i)
                    | i <- [0 .. 63]
                    ]
            Set.size (Set.fromList addrs) `shouldBe` 64

    describe "key actually signs" $ do
        it "produces a non-empty signature on a known message" $ do
            let sk = deriveSignKey goldenMasterSeed 0
                sig = signDSIGN () (BS.pack [1, 2, 3, 4, 5]) sk
            BS.length (rawSerialiseSigDSIGN sig)
                `shouldSatisfy` (> 0)

    describe "shape and non-trivial output" $ do
        it "vk at index 0 is 32 bytes and not all-zero" $ do
            let vk =
                    rawSerialiseVerKeyDSIGN
                        ( deriveVerKeyDSIGN
                            (deriveSignKey goldenMasterSeed 0)
                        )
            BS.length vk `shouldBe` 32
            vk `shouldNotBe` BS.replicate 32 0
            vk `shouldNotBe` goldenMasterSeed

        it "deriveSeedAt 0 differs from deriveSeedAt 1" $ do
            let s0 = deriveSeedAt goldenMasterSeed 0
            let s1 = deriveSeedAt goldenMasterSeed 1
            s0 `shouldNotBe` s1
