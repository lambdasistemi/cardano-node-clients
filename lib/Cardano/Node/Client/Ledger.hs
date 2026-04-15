{-# LANGUAGE DataKinds #-}

module Cardano.Node.Client.Ledger (
    ConwayTx,
) where

import Cardano.Ledger.Alonzo.Core (TopTx, Tx)
import Cardano.Ledger.Conway (ConwayEra)

type ConwayTx = Tx TopTx ConwayEra
