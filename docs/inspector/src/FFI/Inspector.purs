module FFI.Inspector
  ( InspectorResult
  , runInspector
  , runInspectorRpc
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
foreign import runInspectorRpcImpl :: String -> String -> String -> Effect (Promise InspectorResult)

runInspector :: String -> Aff InspectorResult
runInspector = toAffE <<< runInspectorImpl

runInspectorRpc :: String -> String -> String -> Aff InspectorResult
runInspectorRpc txCbor method path = toAffE (runInspectorRpcImpl txCbor method path)
