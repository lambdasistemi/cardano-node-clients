module Main (main) where

import Prelude

import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String (trim) as String
import Effect (Effect)
import Effect.Aff (attempt)
import Effect.Aff.Class (class MonadAff)
import Effect.Class (liftEffect)
import Effect.Exception (message)
import FFI.Blockfrost (Network(..))
import FFI.Clipboard (copy) as Clipboard
import FFI.Inspector (InspectorResult, runInspector)
import FFI.Json (pretty) as Json
import FFI.Storage as Storage
import Provider (Provider(..))
import Provider as Provider
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)

blockfrostKey :: String
blockfrostKey = "blockfrost_project_id"

koiosKey :: String
koiosKey = "koios_bearer_token"

providerKey :: String
providerKey = "provider"

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  bf   <- liftEffect (Storage.getItem blockfrostKey)
  kOS  <- liftEffect (Storage.getItem koiosKey)
  prov <- liftEffect (Storage.getItem providerKey)
  let initialProv = case prov of
        "Koios"      -> Koios
        _            -> Blockfrost
  runUI (inspectorComponent { bf, koios: kOS, prov: initialProv }) unit body

data Mode = ByHash | ByHex

derive instance eqMode :: Eq Mode

type State =
  { provider :: Provider
  , blockfrostKey :: String
  , koiosBearer :: String
  , mode :: Mode
  , network :: Network
  , txHash :: String
  , txHex :: String
  , result :: Maybe InspectorResult
  , running :: Boolean
  , copied :: Boolean
  , fetchError :: Maybe String
  }

type InitialKeys =
  { bf :: String
  , koios :: String
  , prov :: Provider
  }

data Action
  = SetBlockfrostKey String
  | SetKoiosBearer String
  | SelectProvider Provider
  | SelectMode Mode
  | SelectNetwork Network
  | SetTxHash String
  | SetTxHex String
  | Decode
  | Copy

inspectorComponent
  :: forall q i o m
   . MonadAff m
  => InitialKeys
  -> H.Component q i o m
inspectorComponent initial =
  H.mkComponent
    { initialState: \_ ->
        { provider: initial.prov
        , blockfrostKey: initial.bf
        , koiosBearer: initial.koios
        , mode: ByHash
        , network: Mainnet
        , txHash: ""
        , txHex: ""
        , result: Nothing
        , running: false
        , copied: false
        , fetchError: Nothing
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
              "Decodes Cardano Conway-era transactions using the upstream Haskell ledger code "
          , HH.strong_ [ HH.text "unchanged" ]
          , HH.text " — the same "
          , HH.code_ [ HH.text "cardano-ledger-conway" ]
          , HH.text " + "
          , HH.code_ [ HH.text "cardano-ledger-binary" ]
          , HH.text " packages IntersectMBO ships for node and CLI, cross-compiled to "
          , HH.code_ [ HH.text "wasm32-wasi" ]
          , HH.text " and loaded in the browser via a WASI shim."
          ]
      , renderProvider state
      , renderModeTabs state
      , renderBody state
      , renderResult state
      ]

  renderProvider state =
    HH.div_
      [ HH.h2_ [ HH.text "Chain data provider" ]
      , HH.div
          [ HP.style "margin-bottom: 0.5rem;" ]
          [ HH.text "Source: "
          , providerRadio state Blockfrost "Blockfrost (API key required)"
          , providerRadio state Koios      "Koios (bearer token required in browser; free tier at koios.rest)"
          ]
      , HH.p_
          [ HH.text "Used only for the "
          , HH.strong_ [ HH.text "by tx hash" ]
          , HH.text " mode. Keys are kept in your browser's localStorage; the CBOR never leaves your machine once fetched."
          ]
      , case state.provider of
          Blockfrost ->
            HH.div_
              [ HH.input
                  [ HP.type_ HP.InputText
                  , HP.placeholder "Blockfrost project_id (mainnet.../preprod.../preview...)"
                  , HP.value state.blockfrostKey
                  , HE.onValueInput SetBlockfrostKey
                  , HP.style "width: 100%; font-family: ui-monospace, monospace;"
                  ]
              , HH.p
                  [ HP.style "margin-top: 0.25rem; font-size: 0.85rem; color: #555;" ]
                  [ HH.text "Free tier at "
                  , HH.a
                      [ HP.href "https://blockfrost.io/"
                      , HP.target "_blank"
                      , HP.rel "noopener noreferrer"
                      ]
                      [ HH.text "blockfrost.io" ]
                  , HH.text "."
                  ]
              ]
          Koios ->
            HH.div_
              [ HH.input
                  [ HP.type_ HP.InputText
                  , HP.placeholder "Koios bearer token (required for browser use)"
                  , HP.value state.koiosBearer
                  , HE.onValueInput SetKoiosBearer
                  , HP.style "width: 100%; font-family: ui-monospace, monospace;"
                  ]
              , HH.p
                  [ HP.style "margin-top: 0.25rem; font-size: 0.85rem; color: #555;" ]
                  [ HH.text "Koios intentionally strips CORS on unauthenticated requests (see "
                  , HH.a
                      [ HP.href "https://github.com/cardano-community/koios-artifacts/issues/397"
                      , HP.target "_blank"
                      , HP.rel "noopener noreferrer"
                      ]
                      [ HH.text "issue #397" ]
                  , HH.text "). Free bearer tokens at "
                  , HH.a
                      [ HP.href "https://koios.rest/pricing/Pricing.html"
                      , HP.target "_blank"
                      , HP.rel "noopener noreferrer"
                      ]
                      [ HH.text "koios.rest/pricing" ]
                  , HH.text " — the free tier covers 50k req/day. Without a token, use the CLI script and paste in 'By CBOR hex' mode."
                  ]
              ]
      , HH.div
          [ HP.style "margin-top: 0.5rem; font-size: 0.9rem;" ]
          [ HH.text "Network: "
          , networkRadio state Mainnet "mainnet"
          , networkRadio state Preprod "preprod"
          , networkRadio state Preview "preview"
          ]
      ]

  providerRadio state prov label =
    HH.label
      [ HP.style "margin-right: 1rem; cursor: pointer;" ]
      [ HH.input
          [ HP.type_ HP.InputRadio
          , HP.name "provider"
          , HP.checked (state.provider == prov)
          , HE.onChange (\_ -> SelectProvider prov)
          ]
      , HH.text (" " <> label)
      ]

  networkRadio state net label =
    HH.label
      [ HP.style "margin-right: 1rem; cursor: pointer;" ]
      [ HH.input
          [ HP.type_ HP.InputRadio
          , HP.name "network"
          , HP.checked (state.network == net)
          , HE.onChange (\_ -> SelectNetwork net)
          ]
      , HH.text (" " <> label)
      ]

  renderModeTabs state =
    HH.div
      [ HP.style "margin-top: 1.5rem;" ]
      [ HH.h2_ [ HH.text "Input" ]
      , HH.div_
          [ modeButton state ByHash "By tx hash"
          , modeButton state ByHex  "By CBOR hex"
          ]
      ]

  modeButton state mode label =
    HH.button
      [ HE.onClick (\_ -> SelectMode mode)
      , HP.style (
          "margin-right: 0.5rem; padding: 0.35rem 0.75rem; font-size: 0.9rem; "
            <> (if state.mode == mode
                 then "border: 1px solid #333; background: #eee;"
                 else "border: 1px solid #ccc; background: transparent;"))
      ]
      [ HH.text label ]

  renderBody state = case state.mode of
    ByHash ->
      HH.div_
        [ HH.input
            [ HP.type_ HP.InputText
            , HP.placeholder "64-char tx hash"
            , HP.value state.txHash
            , HE.onValueInput SetTxHash
            , HP.style "width: 100%; font-family: ui-monospace, monospace;"
            ]
        , HH.div_
            [ HH.button
                [ HP.disabled state.running
                , HE.onClick (\_ -> Decode)
                ]
                [ HH.text (if state.running then "Fetching & decoding..." else "Fetch & decode") ]
            ]
        ]
    ByHex ->
      HH.div_
        [ HH.textarea
            [ HP.value state.txHex
            , HP.placeholder "Conway tx CBOR hex..."
            , HP.rows 8
            , HE.onValueInput SetTxHex
            ]
        , HH.div_
            [ HH.button
                [ HP.disabled state.running
                , HE.onClick (\_ -> Decode)
                ]
                [ HH.text (if state.running then "Decoding..." else "Decode") ]
            ]
        ]

  renderResult state =
    case state.fetchError of
      Just err ->
        HH.div
          [ HP.style "color: #b00; margin-top: 1rem;" ]
          [ HH.strong_ [ HH.text "Fetch error: " ]
          , HH.text err
          ]
      Nothing -> case state.result of
        Nothing -> HH.text ""
        Just r ->
          HH.div_
            [ HH.div_
                [ HH.h2_ [ HH.text (if r.exitOk then "Decoded JSON" else "Error") ]
                , if r.exitOk
                    then
                      HH.button
                        [ HE.onClick (\_ -> Copy)
                        , HP.style "margin-left: 1rem; font-size: 0.875rem;"
                        ]
                        [ HH.text (if state.copied then "Copied!" else "Copy JSON") ]
                    else HH.text ""
                ]
            , HH.pre_ [ HH.text (Json.pretty r.stdout) ]
            , if r.stderr == "" then HH.text ""
              else
                HH.div_
                  [ HH.h2_ [ HH.text "stderr" ]
                  , HH.pre_ [ HH.text r.stderr ]
                  ]
            ]

  handleAction = case _ of
    SetBlockfrostKey s -> do
      H.modify_ _ { blockfrostKey = s }
      liftEffect (Storage.setItem blockfrostKey s)
    SetKoiosBearer s -> do
      H.modify_ _ { koiosBearer = s }
      liftEffect (Storage.setItem koiosKey s)
    SelectProvider p -> do
      H.modify_ _ { provider = p, fetchError = Nothing }
      liftEffect (Storage.setItem providerKey (Provider.providerName p))
    SelectMode m -> H.modify_ _ { mode = m, fetchError = Nothing }
    SelectNetwork n -> H.modify_ _ { network = n, fetchError = Nothing }
    SetTxHash s -> H.modify_ _ { txHash = s, copied = false, fetchError = Nothing }
    SetTxHex s -> H.modify_ _ { txHex = s, copied = false, fetchError = Nothing }
    Decode -> do
      st <- H.get
      H.modify_ _ { running = true, result = Nothing, copied = false, fetchError = Nothing }
      hexE <- case st.mode of
        ByHex -> pure (Right (String.trim st.txHex))
        ByHash ->
          let key = case st.provider of
                Blockfrost -> String.trim st.blockfrostKey
                Koios      -> String.trim st.koiosBearer
              trimmedHash = String.trim st.txHash
          in
            if Provider.needsKey st.provider && key == ""
              then pure (Left (Provider.providerName st.provider <> " key not set."))
              else if trimmedHash == ""
                then pure (Left "Tx hash is empty.")
                else do
                  e <- H.liftAff (attempt (Provider.fetchTxCbor st.provider st.network key trimmedHash))
                  case e of
                    Left err ->
                      let raw = message err
                          diag = case st.provider of
                            Koios | raw == "Failed to fetch" ->
                              if String.trim st.koiosBearer == ""
                                then "Koios blocks anonymous browser requests by design (CORS stripped). Register at koios.rest/pricing for a free bearer token (50k req/day), paste it above, and retry. Or use scripts/fetch-tx-cbor.sh <hash> locally and paste the hex."
                                else "Koios rejected the request. Check the bearer token is valid and the network matches (mainnet/preprod/preview)."
                            _ -> raw
                      in pure (Left diag)
                    Right cbor -> pure (Right cbor)
      case hexE of
        Left err -> H.modify_ _ { running = false, fetchError = Just err }
        Right h -> do
          r <- H.liftAff (runInspector h)
          H.modify_ _ { running = false, result = Just r }
    Copy -> do
      mr <- H.gets _.result
      case mr of
        Nothing -> pure unit
        Just r -> do
          H.liftAff (Clipboard.copy (Json.pretty r.stdout))
          H.modify_ _ { copied = true }
