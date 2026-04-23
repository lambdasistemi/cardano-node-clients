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
      [ HH.h1_ [ HH.text "Conway tx inspector (WASM)" ]
      , HH.p_
          [ HH.text
              "Paste a Conway-era transaction CBOR in hex. The Haskell decoder is embedded as a wasm32-wasi binary."
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
