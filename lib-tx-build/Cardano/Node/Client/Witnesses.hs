{- |
Module      : Cardano.Node.Client.Witnesses
Description : Witness counting helpers
License     : Apache-2.0

Helpers for deriving witness counts from transaction
body fields and resolved UTxOs.
-}
module Cardano.Node.Client.Witnesses (
    estimatedKeyWitnessCount,
) where

import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Withdrawals (..))
import Cardano.Ledger.Api.Tx.Body (
    TxBody,
    certsTxBodyL,
    reqSignerHashesTxBodyL,
    votingProceduresTxBodyL,
    withdrawalsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    addrTxOutL,
 )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance (
    VotingProcedures (..),
 )
import Cardano.Ledger.Conway.TxCert (
    getVKeyWitnessConwayTxCert,
 )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.Credentials (
    accountKeyHashBytes,
    addrPaymentKeyHashBytes,
    keyHashBytes,
    voterKeyHashBytes,
 )

estimatedKeyWitnessCount ::
    TxBody l ConwayEra ->
    Set.Set TxIn ->
    [(TxIn, TxOut ConwayEra)] ->
    Int
estimatedKeyWitnessCount body bodyInputs inputUtxos =
    max 1 $
        Set.size $
            inputWitnesses
                <> certWitnesses
                <> requiredSignerWitnesses
                <> votingWitnesses
                <> withdrawalWitnesses
  where
    inputWitnesses =
        Set.fromList
            [ kh
            | (txIn, txOut) <- inputUtxos
            , Set.member txIn bodyInputs
            , Just kh <- [addrPaymentKeyHashBytes (txOut ^. addrTxOutL)]
            ]
    certWitnesses =
        Set.fromList
            [ keyHashBytes kh
            | cert <- toList (body ^. certsTxBodyL)
            , Just kh <- [getVKeyWitnessConwayTxCert cert]
            ]
    requiredSignerWitnesses =
        Set.fromList
            [ keyHashBytes kh
            | kh <- Set.toList (body ^. reqSignerHashesTxBodyL)
            ]
    votingWitnesses =
        let VotingProcedures procedures =
                body ^. votingProceduresTxBodyL
         in Set.fromList
                [ bytes
                | voter <- Map.keys procedures
                , Just bytes <- [voterKeyHashBytes voter]
                ]
    withdrawalWitnesses =
        let Withdrawals withdrawals =
                body ^. withdrawalsTxBodyL
         in Set.fromList
                [ kh
                | account <- Map.keys withdrawals
                , Just kh <- [accountKeyHashBytes account]
                ]
