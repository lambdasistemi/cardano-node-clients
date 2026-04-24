module FFI.Json
  ( pretty
  ) where

foreign import prettyImpl :: String -> String

pretty :: String -> String
pretty = prettyImpl
