module Provider
  ( Provider(..)
  , providerName
  , needsKey
  , fetchTxCbor
  ) where

import Prelude

import Effect.Aff (Aff)
import FFI.Blockfrost (Network)
import FFI.Blockfrost as Blockfrost
import FFI.Koios as Koios

data Provider = Blockfrost | Koios

derive instance eqProvider :: Eq Provider

providerName :: Provider -> String
providerName = case _ of
  Blockfrost -> "Blockfrost"
  Koios      -> "Koios"

-- | Blockfrost requires a project ID. Koios accepts an optional bearer
-- token for higher rate limits; it works without one, so the key field
-- is optional.
needsKey :: Provider -> Boolean
needsKey = case _ of
  Blockfrost -> true
  Koios      -> false

-- | Unified fetch. `key` is the project ID for Blockfrost or an optional
-- bearer token for Koios (empty string = no auth).
fetchTxCbor :: Provider -> Network -> String -> String -> Aff String
fetchTxCbor = case _ of
  Blockfrost -> Blockfrost.fetchTxCbor
  Koios      -> Koios.fetchTxCbor
