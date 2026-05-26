{-# LANGUAGE OverloadedStrings #-}

module Cardano.Node.Client.UTxOIndexer.BlockExtractSpec (spec) where

import Cardano.Chain.Block qualified as ByronBlock
import Cardano.Chain.Common qualified as ByronCommon
import Cardano.Chain.Delegation qualified as ByronDelegation
import Cardano.Chain.Slotting qualified as ByronSlot
import Cardano.Chain.Ssc qualified as ByronSsc
import Cardano.Chain.UTxO qualified as ByronUTxO
import Cardano.Chain.Update qualified as ByronUpdate
import Cardano.Crypto qualified as ByronCrypto
import Cardano.Crypto.Hashing qualified as ByronHashing
import Cardano.Ledger.Address (
    Addr (..),
    BootstrapAddress (..),
    serialiseAddr,
 )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Val (inject)
import Cardano.Node.Client.Types (Block)
import Cardano.Node.Client.UTxOIndexer.BlockExtract (extractBlock)
import Cardano.Node.Client.UTxOIndexer.IndexerOp (UtxoOp (..))
import Cardano.Node.Client.UTxOIndexer.Types (
    Address (..),
    SlotNo (..),
    TxIn (..),
    TxOut (..),
 )
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty (..))
import Data.Word (Word64)
import Ouroboros.Consensus.Byron.Ledger qualified as ConsensusByron
import Ouroboros.Consensus.Cardano.Block qualified as ConsensusCardano
import Test.Hspec (Spec, describe, it, shouldBe)

spec :: Spec
spec =
    describe "Cardano.Node.Client.UTxOIndexer.BlockExtract" $
        it "extracts Byron transaction inputs and outputs" $ do
            let inputTxId =
                    ByronHashing.unsafeHashFromBytes
                        (BS.replicate 32 0x11)
                input = ByronUTxO.TxInUtxo inputTxId 3
                tx =
                    ByronUTxO.UnsafeTx
                        (input :| [])
                        (byronOutput :| [])
                        (ByronCommon.mkAttributes ())
                txAux = ByronUTxO.mkTxAux tx mempty
                (slot, ops) = extractBlock (byronBlock txAux)

            slot `shouldBe` SlotNo 42
            ops
                `shouldBe` [ UtxoSpend
                                TxIn
                                    { txInId =
                                        ByronHashing.hashToBytes inputTxId
                                    , txInIx = 3
                                    }
                           , UtxoCreate
                                TxIn
                                    { txInId =
                                        ByronHashing.hashToBytes
                                            (ByronHashing.serializeCborHash tx)
                                    , txInIx = 0
                                    }
                                expectedAddress
                                expectedTxOut
                           ]

byronBlock :: ByronUTxO.TxAux -> Block
byronBlock txAux =
    ConsensusCardano.BlockByron
        ( ConsensusByron.annotateByronBlock byronEpochSlots $
            ByronBlock.mkBlockExplicit
                protocolMagic
                (ByronUpdate.ProtocolVersion 0 0 0)
                ( ByronUpdate.SoftwareVersion
                    (ByronUpdate.ApplicationName "cnc-test")
                    0
                )
                (ByronHashing.unsafeHashFromBytes (BS.replicate 32 0x22))
                (ByronCommon.ChainDifficulty 1)
                byronEpochSlots
                (ByronSlot.SlotNumber 42)
                delegateSigningKey
                delegationCertificate
                (byronBody txAux)
        )

byronEpochSlots :: ByronSlot.EpochSlots
byronEpochSlots = ByronSlot.EpochSlots 21_600

protocolMagic :: ByronCrypto.ProtocolMagicId
protocolMagic = ByronCrypto.ProtocolMagicId 764_824_073

delegationCertificate :: ByronDelegation.Certificate
delegationCertificate =
    ByronDelegation.signCertificate
        protocolMagic
        delegateVerificationKey
        0
        (ByronCrypto.noPassSafeSigner issuerSigningKey)

issuerSigningKey :: ByronCrypto.SigningKey
issuerSigningKey = snd issuerKeyPair

delegateVerificationKey :: ByronCrypto.VerificationKey
delegateVerificationKey = fst delegateKeyPair

delegateSigningKey :: ByronCrypto.SigningKey
delegateSigningKey = snd delegateKeyPair

issuerKeyPair :: (ByronCrypto.VerificationKey, ByronCrypto.SigningKey)
issuerKeyPair =
    ByronCrypto.deterministicKeyGen (BS.replicate 32 0xA1)

delegateKeyPair :: (ByronCrypto.VerificationKey, ByronCrypto.SigningKey)
delegateKeyPair =
    ByronCrypto.deterministicKeyGen (BS.replicate 32 0xA2)

byronBody :: ByronUTxO.TxAux -> ByronBlock.Body
byronBody txAux =
    ByronBlock.Body
        (ByronUTxO.mkTxPayload [txAux])
        ByronSsc.SscPayload
        (ByronDelegation.unsafePayload [])
        (ByronUpdate.payload Nothing [])

byronOutput :: ByronUTxO.TxOut
byronOutput = ByronUTxO.TxOut byronAddress lovelace

expectedAddress :: Address
expectedAddress =
    Address
        ( serialiseAddr
            (AddrBootstrap (BootstrapAddress byronAddress))
        )

expectedTxOut :: TxOut
expectedTxOut =
    TxOut
        ( serialize'
            (Ledger.eraProtVerLow @ConwayEra)
            ( mkBasicTxOut @ConwayEra
                (AddrBootstrap (BootstrapAddress byronAddress))
                (inject $ Coin $ toInteger lovelaceValue)
            )
        )

byronAddress :: ByronCommon.Address
byronAddress =
    either
        (error . show)
        id
        ( ByronCommon.decodeAddressBase58
            "DdzFFzCqrhsq3KjLtT51mESbZ4RepiHPzLqEhamexVFTJpGbCXmh7qSxnHvaL88QmtVTD1E1sjx8Z1ZNDhYmcBV38ZjDST9kYVxSkhcw"
        )

lovelace :: ByronCommon.Lovelace
lovelace =
    either
        (error . show)
        id
        (ByronCommon.mkLovelace lovelaceValue)

lovelaceValue :: Word64
lovelaceValue = 12_345_678
