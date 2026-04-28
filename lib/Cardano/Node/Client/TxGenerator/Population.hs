{- |
Module      : Cardano.Node.Client.TxGenerator.Population
Description : Deterministic key/address derivation by index
License     : Apache-2.0

Derives an Ed25519 signing key and a payment-only
enterprise address from a 32-byte master seed plus a
'Word64' index, using the flat (non-hierarchical) scheme
fixed in @specs/034-cardano-tx-generator/research.md@
decision D3:

@
seed_i = blake2b_256 (masterSeed <> bigEndian64 i)
sk_i   = genKeyDSIGN (mkSeedFromBytes seed_i)
addr_i = enterpriseAddr (hashKey (VKey (deriveVerKeyDSIGN sk_i)))
@

The scheme is *not* CIP-1852 / BIP32 conformant — there
is no chain code, no soft/hard distinction, no path
hierarchy. It is purely a deterministic function from
@(masterSeed, i) :: (ByteString, Word64)@ to a key. That
is enough for the tx-generator's "growing population"
contract (FR-004) and lets the daemon stay inside the
in-tree single-key Ed25519 surface.

Determinism here is load-bearing for FR-002 and SC-002:
two daemons holding the same @master.seed@ produce the
same address sequence forever. Unit tests in
@PopulationSpec@ pin both this property and a small
golden vector.
-}
module Cardano.Node.Client.TxGenerator.Population (
    -- * Derivation
    deriveSignKey,
    deriveAddr,

    -- * Faucet helpers (raw 32-byte seed)
    mkSignKey,
    enterpriseAddrFromSignKey,

    -- * Internals (exposed for tests)
    deriveSeedAt,
) where

import Cardano.Crypto.DSIGN (
    DSIGNAlgorithm (deriveVerKeyDSIGN, genKeyDSIGN),
    Ed25519DSIGN,
    SignKeyDSIGN,
 )
import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Credential (
    Credential (KeyHashObj),
    StakeReference (StakeRefNull),
 )
import Cardano.Ledger.Keys (
    KeyHash,
    KeyRole (Payment),
    VKey (..),
    hashKey,
 )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as Builder
import Data.ByteString.Lazy qualified as LBS
import Data.Word (Word64)

-- | Length of an Ed25519 seed in bytes.
seedBytes :: Int
seedBytes = 32

{- | The 32 bytes used as the Ed25519 seed at index @i@.
Defined as @blake2b_256 (masterSeed || bigEndian64 i)@,
truncated/padded to 32 bytes (Blake2b-256 is already 32
bytes; the truncation is a defensive no-op).
-}
deriveSeedAt :: ByteString -> Word64 -> ByteString
deriveSeedAt masterSeed i =
    BS.take
        seedBytes
        ( hashToBytes
            (hashWith @Blake2b_256 id (masterSeed <> indexBytes))
        )
  where
    indexBytes :: ByteString
    indexBytes =
        LBS.toStrict
            ( Builder.toLazyByteString
                (Builder.word64BE i)
            )

{- | The deterministic Ed25519 signing key at population
index @i@.
-}
deriveSignKey ::
    ByteString -> Word64 -> SignKeyDSIGN Ed25519DSIGN
deriveSignKey masterSeed i =
    mkSignKey (deriveSeedAt masterSeed i)

{- | Construct an Ed25519 signing key directly from 32
raw seed bytes. Used by the daemon's startup to load the
faucet's signing key from its on-disk file. Bytes shorter
than 32 are padded with zeroes by 'mkSeedFromBytes'; the
caller should validate the length.
-}
mkSignKey :: ByteString -> SignKeyDSIGN Ed25519DSIGN
mkSignKey = genKeyDSIGN . mkSeedFromBytes

{- | The payment-only enterprise address at population
index @i@ on the given 'Network'. No stake credential.
-}
deriveAddr ::
    Network -> ByteString -> Word64 -> Addr
deriveAddr net masterSeed i =
    enterpriseAddrFromSignKey net (deriveSignKey masterSeed i)

{- | The payment-only enterprise address that owns the
given Ed25519 signing key on the given 'Network'. Used
both for the population (via 'deriveAddr') and for the
faucet (whose key is loaded directly from disk).
-}
enterpriseAddrFromSignKey ::
    Network -> SignKeyDSIGN Ed25519DSIGN -> Addr
enterpriseAddrFromSignKey net sk =
    Addr net (KeyHashObj kh) StakeRefNull
  where
    kh :: KeyHash Payment
    kh = hashKey (VKey (deriveVerKeyDSIGN sk))
