module FFI.Clipboard
  ( copy
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Effect (Effect)
import Effect.Aff (Aff)

foreign import copyImpl :: String -> Effect (Promise Unit)

copy :: String -> Aff Unit
copy = toAffE <<< copyImpl
