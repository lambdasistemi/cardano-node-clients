module FFI.Storage
  ( getItem
  , setItem
  ) where

import Prelude

import Effect (Effect)

foreign import getItemImpl :: String -> Effect String
foreign import setItemImpl :: String -> String -> Effect Unit

getItem :: String -> Effect String
getItem = getItemImpl

setItem :: String -> String -> Effect Unit
setItem = setItemImpl
