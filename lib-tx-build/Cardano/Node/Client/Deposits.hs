{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.Deposits
Description : Transaction deposit accounting
License     : Apache-2.0

Helpers for deriving the ADA deposit/refund delta
introduced by transaction body fields.
-}
module Cardano.Node.Client.Deposits (
    bodyDepositDelta,
) where

import Data.Foldable (toList)
import Lens.Micro ((^.))

import Cardano.Ledger.Api.Tx.Body (
    TxBody,
    certsTxBodyL,
    proposalProceduresTxBodyL,
 )
import Cardano.Ledger.BaseTypes (
    StrictMaybe (SJust, SNothing),
 )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance (
    ProposalProcedure (..),
 )
import Cardano.Ledger.Conway.TxCert (
    ConwayDelegCert (..),
    ConwayGovCert (..),
    ConwayTxCert (..),
 )
import Cardano.Ledger.Core (
    PParams,
    getTotalDepositsTxCerts,
 )

bodyDepositDelta ::
    PParams ConwayEra ->
    TxBody l ConwayEra ->
    Integer
bodyDepositDelta pp body =
    coinInteger
        ( getTotalDepositsTxCerts
            pp
            (const False)
            (body ^. certsTxBodyL)
        )
        - sum (certRefund <$> toList (body ^. certsTxBodyL))
        + sum
            ( proposalDeposit
                <$> toList (body ^. proposalProceduresTxBodyL)
            )

certRefund ::
    ConwayTxCert ConwayEra ->
    Integer
certRefund =
    \case
        ConwayTxCertDeleg (ConwayUnRegCert _ refund) ->
            strictMaybeCoin refund
        ConwayTxCertGov (ConwayUnRegDRep _ refund) ->
            coinInteger refund
        _ ->
            0

proposalDeposit :: ProposalProcedure ConwayEra -> Integer
proposalDeposit (ProposalProcedure deposit _ _ _) =
    coinInteger deposit

strictMaybeCoin :: StrictMaybe Coin -> Integer
strictMaybeCoin =
    \case
        SJust coin ->
            coinInteger coin
        SNothing ->
            0

coinInteger :: Coin -> Integer
coinInteger (Coin value) =
    value
