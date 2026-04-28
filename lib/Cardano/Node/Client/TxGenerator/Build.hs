{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Cardano.Node.Client.TxGenerator.Build
Description : TxBuild DSL composition for the tx-generator
License     : Apache-2.0

Builds the transactions the daemon submits:

* 'refillTx' — pull from the faucet to a freshly derived
  population address (T008).

* @transactTx@ — fan out one source UTxO into K
  destinations + one change output. Lands in T011.

Internally uses the in-tree TxBuild DSL and its 'build'
runner; signing / submission live with the caller in
'Cardano.Node.Client.TxGenerator.Daemon'.
-}
module Cardano.Node.Client.TxGenerator.Build (
    -- * Refill arm (T008)
    refillTx,
    BuildResult,
) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams (PParams)
import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Coin (Coin)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Ledger.Val (inject)
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.TxBuild (
    InterpretIO (..),
    TxBuild,
    build,
    payTo,
    spend,
 )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

{- | Result of a build helper: either a textual error
(failed to balance, fee-not-converged, etc.) or the
unsigned 'ConwayTx'.
-}
type BuildResult = Either Text ConwayTx

{- | An empty query GADT used when a 'TxBuild' program has
no @ctx@ calls (refill is one such case — the source
UTxO and the destination address are known up-front).
-}
data NoQ a

interpretNoQ :: InterpretIO NoQ
interpretNoQ = InterpretIO $ \case {}

{- | An empty user-error type used when a 'TxBuild'
program has no @valid \/ CustomFail@ predicates — refill
relies entirely on the built-in 'LedgerCheck' set.
-}
data NoErr deriving stock (Show, Eq)

{- | Build the unsigned tx for one refill: spend the
chosen faucet UTxO, send @amount@ to the fresh
population address, and let the balancer route the
residue back to @changeAddr@ (the faucet) as the change
output.

The caller (the daemon) attaches the faucet key witness
and submits via LTxS.

No scripts are involved; the ExUnits evaluator is the
constant-empty function.
-}
refillTx ::
    -- | protocol parameters (queried once at startup)
    PParams ConwayEra ->
    -- | the chosen faucet UTxO
    (TxIn, TxOut ConwayEra) ->
    -- | the fresh population address
    Addr ->
    -- | refill amount (lovelace)
    Coin ->
    -- | change address (the faucet)
    Addr ->
    IO BuildResult
refillTx pp faucetUtxo freshAddr amount changeAddr = do
    let prog :: TxBuild NoQ NoErr ()
        prog = do
            _ <- spend (fst faucetUtxo)
            _ <- payTo freshAddr (inject amount)
            pure ()
        evalNoScripts _ = pure Map.empty
    result <-
        build
            pp
            interpretNoQ
            evalNoScripts
            [faucetUtxo]
            []
            changeAddr
            prog
    pure $ case result of
        Left err ->
            Left (Text.pack (show err))
        Right tx -> Right tx
