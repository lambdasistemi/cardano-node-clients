module FFI.Koios
  ( fetchTxCbor
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Effect (Effect)
import Effect.Aff (Aff)
import FFI.Blockfrost (Network, networkName)

foreign import fetchTxCborImpl
  :: String -- network
  -> String -- bearer (empty string = none)
  -> String -- tx hash
  -> Effect (Promise String)

fetchTxCbor :: Network -> String -> String -> Aff String
fetchTxCbor net bearer hash =
  toAffE (fetchTxCborImpl (networkName net) bearer hash)
