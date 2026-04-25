module FFI.Inspector
  ( InspectorResult
  , runInspector
  , runLedgerOperation
  ) where

import Prelude

import Control.Promise (Promise, toAffE)
import Effect (Effect)
import Effect.Aff (Aff)

type InspectorResult =
  { stdout :: String
  , stderr :: String
  , exitOk :: Boolean
  }

foreign import runInspectorImpl :: String -> Effect (Promise InspectorResult)
foreign import runLedgerOperationImpl :: String -> String -> String -> Effect (Promise InspectorResult)

runInspector :: String -> Aff InspectorResult
runInspector = toAffE <<< runInspectorImpl

runLedgerOperation :: String -> String -> String -> Aff InspectorResult
runLedgerOperation txCbor op path = toAffE (runLedgerOperationImpl txCbor op path)
