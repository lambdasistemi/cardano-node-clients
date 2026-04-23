module Main (main) where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import FFI.Inspector (InspectorResult, runInspector)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  runUI inspectorComponent unit body

type State =
  { input :: String
  , result :: Maybe InspectorResult
  , running :: Boolean
  }

data Action
  = SetInput String
  | Decode

inspectorComponent :: forall q i o m. MonadAff m => H.Component q i o m
inspectorComponent =
  H.mkComponent
    { initialState: \_ ->
        { input: ""
        , result: Nothing
        , running: false
        }
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handleAction }
    }
  where

  render state =
    HH.div_
      [ HH.h1_ [ HH.text "Conway tx inspector" ]
      , HH.p_
          [ HH.text
              "This page decodes Cardano Conway-era transactions using the upstream Haskell ledger code "
          , HH.strong_ [ HH.text "unchanged" ]
          , HH.text
              " — the same "
          , HH.code_ [ HH.text "cardano-ledger-conway" ]
          , HH.text " + "
          , HH.code_ [ HH.text "cardano-ledger-binary" ]
          , HH.text
              " packages IntersectMBO ships for node and CLI, cross-compiled to "
          , HH.code_ [ HH.text "wasm32-wasi" ]
          , HH.text
              " via GHC's WASM backend and loaded here through a browser WASI shim. No re-implementation, no CBOR re-encode: bytes go in, the ledger decoder runs, structural JSON comes out."
          ]
      , HH.p_
          [ HH.text "Paste a Conway-era transaction CBOR hex below. You can fetch one via Blockfrost: "
          , HH.code_ [ HH.text "GET /txs/{hash}/cbor" ]
          , HH.text "."
          ]
      , HH.textarea
          [ HP.value state.input
          , HP.placeholder "Conway tx hex..."
          , HP.rows 8
          , HE.onValueInput SetInput
          ]
      , HH.div_
          [ HH.button
              [ HP.disabled state.running
              , HE.onClick (\_ -> Decode)
              ]
              [ HH.text (if state.running then "Decoding..." else "Decode") ]
          ]
      , case state.result of
          Nothing -> HH.text ""
          Just r ->
            HH.div_
              [ HH.h2_ [ HH.text (if r.exitOk then "stdout" else "error") ]
              , HH.pre_ [ HH.text r.stdout ]
              , if r.stderr == "" then HH.text ""
                else HH.div_
                  [ HH.h2_ [ HH.text "stderr" ]
                  , HH.pre_ [ HH.text r.stderr ]
                  ]
              ]
      ]

  handleAction = case _ of
    SetInput s -> H.modify_ _ { input = s }
    Decode -> do
      H.modify_ _ { running = true, result = Nothing }
      hex <- H.gets _.input
      r <- H.liftAff (runInspector hex)
      H.modify_ _ { running = false, result = Just r }
