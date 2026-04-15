{- |
Module      : Cardano.Node.Client.Submitter
Description : Protocol-agnostic submit interface
License     : Apache-2.0

Record-of-functions interface for submitting signed
transactions. Protocol-specific implementations provide
constructors (e.g. 'Cardano.Node.Client.N2C.Submitter.mkN2CSubmitter').
-}
module Cardano.Node.Client.Submitter (
    -- * Submitter interface
    Submitter (..),

    -- * Result type
    SubmitResult (..),
) where

import Data.ByteString (ByteString)

import Cardano.Ledger.TxIn (TxId)
import Cardano.Node.Client.Ledger (ConwayTx)

-- | Result of submitting a transaction.
data SubmitResult
    = -- | Transaction accepted into the mempool
      Submitted !TxId
    | -- | Transaction was rejected
      Rejected
        -- | Rejection reason (UTF-8 encoded)
        !ByteString
    deriving stock (Show)

{- | Interface for submitting transactions to the
blockchain.
-}
newtype Submitter m = Submitter
    { submitTx ::
        ConwayTx -> m SubmitResult
    -- ^ Submit a signed transaction
    }
