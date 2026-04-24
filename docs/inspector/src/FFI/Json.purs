module FFI.Json
  ( Inspection
  , Metric
  , MintRow
  , OutputRow
  , inspect
  , pretty
  ) where

foreign import prettyImpl :: String -> String
foreign import inspectImpl :: String -> Inspection

type Metric =
  { label :: String
  , value :: String
  }

type OutputRow =
  { index :: String
  , address :: String
  , coin :: String
  , assets :: String
  , datum :: String
  }

type MintRow =
  { policy :: String
  , assets :: String
  }

type Inspection =
  { valid :: Boolean
  , title :: String
  , subtitle :: String
  , metrics :: Array Metric
  , outputs :: Array OutputRow
  , mint :: Array MintRow
  , inputs :: Array String
  , referenceInputs :: Array String
  , outputNote :: String
  , mintNote :: String
  , inputNote :: String
  }

pretty :: String -> String
pretty = prettyImpl

inspect :: String -> Inspection
inspect = inspectImpl
