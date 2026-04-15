{- |
Module      : Cardano.Node.Client.N2C.Submitter
Description : N2C-backed transaction submitter
License     : Apache-2.0

Production implementation of the 'Submitter'
interface. Sends signed transactions to a local
Cardano node via the N2C LocalTxSubmission
mini-protocol using an 'LTxSChannel' (see
"Cardano.Node.Client.N2C.Connection").

The ledger 'Tx ConwayEra' is wrapped into a
consensus 'GenTx Block' before submission.
Rejection reasons are serialized to 'ByteString'
and returned as 'Rejected'.
-}
module Cardano.Node.Client.N2C.Submitter (
    -- * Construction
    mkN2CSubmitter,
) where

import Data.ByteString.Char8 qualified as B8

import Cardano.Ledger.Api.Tx (txIdTx)

import Ouroboros.Consensus.Cardano.Block (
    pattern GenTxConway,
 )
import Ouroboros.Consensus.Cardano.CanHardFork ()
import Ouroboros.Consensus.Ledger.SupportsMempool (
    GenTx,
 )
import Ouroboros.Consensus.Shelley.Ledger.Mempool (
    mkShelleyTx,
 )
import Ouroboros.Consensus.Shelley.Ledger.SupportsProtocol ()

import Cardano.Node.Client.N2C.LocalTxSubmission (
    submitTxN2C,
 )
import Cardano.Node.Client.N2C.Types (
    LTxSChannel,
 )
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Node.Client.Submitter (
    SubmitResult (..),
    Submitter (..),
 )
import Cardano.Node.Client.Types (Block)

{- | Create a 'Submitter IO' backed by the N2C
LocalTxSubmission protocol.
-}
mkN2CSubmitter ::
    -- | LocalTxSubmission channel to the Cardano node
    LTxSChannel ->
    Submitter IO
mkN2CSubmitter ch =
    Submitter
        { submitTx = \tx -> do
            let genTx = toGenTx tx
            result <- submitTxN2C ch genTx
            pure $ case result of
                Right () ->
                    Submitted (txIdTx tx)
                Left err ->
                    Rejected
                        ( B8.pack
                            (show err)
                        )
        }

{- | Convert a ledger 'Tx ConwayEra' to a consensus
'GenTx Block'.
-}
toGenTx :: ConwayTx -> GenTx Block
toGenTx tx = GenTxConway (mkShelleyTx tx)
