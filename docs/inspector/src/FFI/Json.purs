module FFI.Json
  ( Breadcrumb
  , Browser
  , BrowserRow
  , Inspection
  , Metric
  , MintRow
  , OutputRow
  , browse
  , inspect
  , pretty
  ) where

foreign import prettyImpl :: String -> String
foreign import inspectImpl :: String -> Inspection
foreign import browseImpl :: String -> String -> Browser

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

type Breadcrumb =
  { label :: String
  , path :: String
  }

type BrowserRow =
  { label :: String
  , path :: String
  , kind :: String
  , summary :: String
  , copyValue :: String
  , canDive :: Boolean
  }

type Browser =
  { valid :: Boolean
  , title :: String
  , subtitle :: String
  , currentPath :: String
  , currentJson :: String
  , breadcrumbs :: Array Breadcrumb
  , rows :: Array BrowserRow
  }

pretty :: String -> String
pretty = prettyImpl

inspect :: String -> Inspection
inspect = inspectImpl

browse :: String -> String -> Browser
browse = browseImpl
