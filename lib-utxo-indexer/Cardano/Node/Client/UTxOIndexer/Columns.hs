{- |
Module      : Cardano.Node.Client.UTxOIndexer.Columns
Description : Typed-column GADT for the indexer database
License     : Apache-2.0

Database layout for the address->UTxO indexer expressed
against the 'Database.KV.Transaction' abstraction from
@kv-transactions@.

Two live-state columns:

* 'TxInCol' :: @KV TxIn Address@ — primary table keyed
  by the 'TxIn' alone. The chain block consuming an
  input gives us only its 'TxIn'; this column lets us
  resolve the input's address (needed to delete the
  matching 'AddressIndex' row) without scanning.
* 'AddressIndex' :: @KV AddrKey TxOut@ — secondary index
  for address-prefix snapshot queries. Composite key
  @lenByte || address || txId || ix@ so a cursor seek to
  @lenByte || address@ yields every UTxO at that address
  with its full 'TxOut' inline (no second-stage lookup).

A future RocksDB swap is a one-line backend choice via
@mkInMemoryDatabase@ → @mkRocksDBDatabase@; nothing in
this module changes.
-}
module Cardano.Node.Client.UTxOIndexer.Columns (
    -- * Column GADT
    Cols (..),

    -- * Codecs
    txInColCodecs,
    addressIndexCodecs,
) where

import Cardano.Node.Client.UTxOIndexer.Types (
    AddrKey,
    Address (..),
    TxIn,
    TxOut (..),
    addrKeyFromBytes,
    addrKeyToBytes,
    txInFromBytes,
    txInToBytes,
 )
import Control.Lens (Prism', prism')
import Data.ByteString (ByteString)
import Data.GADT.Compare (
    GCompare (..),
    GEq (..),
    GOrdering (..),
 )
import Data.Type.Equality (type (:~:) (Refl))
import Database.KV.Transaction (Codecs (..), KV)

{- | The indexer database's column families. Two live
columns; rollback support lands in a follow-up patch and
adds a third.
-}
data Cols c where
    -- | Primary table: @TxIn → Address@. Lets the
    -- spend-by-TxIn path resolve the consumed UTxO's
    -- address without scanning. Key is 34 bytes fixed.
    TxInCol :: Cols (KV TxIn Address)
    -- | Secondary index: @AddrKey → TxOut@ where
    -- @AddrKey = (Address, TxIn)@ is encoded as
    -- @lenByte || address || txId || ix@. Cursor
    -- prefix-scan by address yields @(TxIn, TxOut)@
    -- pairs directly.
    AddressIndex :: Cols (KV AddrKey TxOut)

instance GEq Cols where
    geq TxInCol TxInCol = Just Refl
    geq AddressIndex AddressIndex = Just Refl
    geq _ _ = Nothing

instance GCompare Cols where
    gcompare TxInCol TxInCol = GEQ
    gcompare TxInCol AddressIndex = GLT
    gcompare AddressIndex TxInCol = GGT
    gcompare AddressIndex AddressIndex = GEQ

{- | Codecs for 'TxInCol'. Both key (34 bytes fixed) and
value (raw address bytes) are length-determined; the
prism is total on encode, partial only on shape on
decode.
-}
txInColCodecs :: Codecs (KV TxIn Address)
txInColCodecs =
    Codecs
        { keyCodec = txInPrism
        , valueCodec = addressPrism
        }

{- | Codecs for 'AddressIndex'. The key codec is total
on the encode side modulo the @maxAddressLength@
invariant baked into 'addrKeyToBytes'; on the decode
side it returns 'Nothing' for any byte string that
does not match the
@lenByte || address(lenByte) || txId(32) || ix(2)@
shape.

The value side is the raw CBOR 'TxOut' as observed on
chain; the indexer never decodes it.
-}
addressIndexCodecs :: Codecs (KV AddrKey TxOut)
addressIndexCodecs =
    Codecs
        { keyCodec = addrKeyPrism
        , valueCodec = txOutPrism
        }

-- Internal --------------------------------------------------------

txInPrism :: Prism' ByteString TxIn
txInPrism = prism' txInToBytes txInFromBytes

addressPrism :: Prism' ByteString Address
addressPrism = prism' unAddress (Just . Address)

addrKeyPrism :: Prism' ByteString AddrKey
addrKeyPrism =
    -- Encoding any address shorter than 256 bytes always
    -- succeeds; we 'error' on the impossible case rather
    -- than thread 'Maybe' through every caller (real
    -- ledger never produces such addresses).
    prism' encode addrKeyFromBytes
  where
    encode k = case addrKeyToBytes k of
        Just bs -> bs
        Nothing ->
            error
                "addrKeyPrism: address exceeds 255 bytes — \
                \invariant violation, ledger never produces \
                \such addresses"

txOutPrism :: Prism' ByteString TxOut
txOutPrism = prism' unTxOut (Just . TxOut)
