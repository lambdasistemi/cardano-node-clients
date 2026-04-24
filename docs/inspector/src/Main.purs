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

persistKeysStorageKey :: String
persistKeysStorageKey = "persist_api_keys"

main :: Effect Unit
main = HA.runHalogenAff do
  body    <- HA.awaitBody
  persist <- liftEffect (Storage.getItem persistKeysStorageKey)
  let persistInitial = persist == "true"
  bf   <- liftEffect
    (if persistInitial then Storage.getItem blockfrostKey else pure "")
  kOS  <- liftEffect
    (if persistInitial then Storage.getItem koiosKey else pure "")
  prov <- liftEffect (Storage.getItem providerKey)
  let initialProv = case prov of
        "Koios"      -> Koios
        _            -> Blockfrost
  runUI
    ( inspectorComponent
        { bf
        , koios: kOS
        , prov: initialProv
        , persistKeys: persistInitial
        }
    ) unit body

data Mode = ByHash | ByHex

derive instance eqMode :: Eq Mode

type State =
  { provider :: Provider
  , blockfrostKey :: String
  , koiosBearer :: String
  , persistKeys :: Boolean
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
  , persistKeys :: Boolean
  }

data Action
  = SetBlockfrostKey String
  | SetKoiosBearer String
  | SelectProvider Provider
  | TogglePersist Boolean
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
        , persistKeys: initial.persistKeys
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
      , renderResult state
      ]

  renderProvider state =
    HH.article_
      [ HH.header_ [ HH.h2_ [ HH.text "Chain data provider" ] ]
      , HH.p_
          [ HH.text "Pick a provider. Both offer a free tier that needs a quick signup — paste the resulting credential below. Used only in the "
          , HH.strong_ [ HH.text "by tx hash" ]
          , HH.text " mode."
          ]
      , HH.fieldset_
          [ HH.legend_ [ HH.text "Source" ]
          , providerRadio state Blockfrost "Blockfrost"
          , providerRadio state Koios      "Koios"
          ]
      , case state.provider of
          Blockfrost ->
            HH.label_
              [ HH.text "Blockfrost project ID (free tier at "
              , HH.a
                  [ HP.href "https://blockfrost.io/auth/signup"
                  , HP.target "_blank"
                  , HP.rel "noopener noreferrer"
                  ]
                  [ HH.text "blockfrost.io signup" ]
              , HH.text ")"
              , HH.input
                  [ HP.type_ HP.InputPassword
                  , HP.placeholder "mainnet... / preprod... / preview..."
                  , HP.value state.blockfrostKey
                  , HE.onValueInput SetBlockfrostKey
                  ]
              ]
          Koios ->
            HH.label_
              [ HH.text "Koios bearer token (free tier at "
              , HH.a
                  [ HP.href "https://koios.rest/auth/Auth.html"
                  , HP.target "_blank"
                  , HP.rel "noopener noreferrer"
                  ]
                  [ HH.text "koios.rest auth" ]
              , HH.text ")"
              , HH.input
                  [ HP.type_ HP.InputPassword
                  , HP.placeholder "eyJhbGciOi..."
                  , HP.value state.koiosBearer
                  , HE.onValueInput SetKoiosBearer
                  ]
              ]
      , HH.fieldset_
          [ HH.legend_ [ HH.text "Network" ]
          , networkRadio state Mainnet "mainnet"
          , networkRadio state Preprod "preprod"
          , networkRadio state Preview "preview"
          ]
      , renderPersistToggle state
      ]

  renderPersistToggle state =
    HH.fieldset_
      [ HH.label_
          [ HH.input
              [ HP.type_ HP.InputCheckbox
              , HH.attr (HH.AttrName "role") "switch"
              , HP.checked state.persistKeys
              , HE.onChecked TogglePersist
              ]
          , HH.text " Persist API credentials across sessions"
          ]
      , HH.small
          [ HP.class_ (HH.ClassName "warning") ]
          [ HH.text
              "⚠ When enabled, the credential is saved in your browser's localStorage "
          , HH.strong_ [ HH.text "in cleartext" ]
          , HH.text
              ". Any JavaScript running on this origin (including future updates of this page) can read it. When disabled (default), the credential stays in memory only and is lost on reload."
          ]
      ]

  providerRadio state prov label =
    HH.label_
      [ HH.input
          [ HP.type_ HP.InputRadio
          , HP.name "provider"
          , HP.checked (state.provider == prov)
          , HE.onChange (\_ -> SelectProvider prov)
          ]
      , HH.text (" " <> label)
      ]

  networkRadio state net label =
    HH.label_
      [ HH.input
          [ HP.type_ HP.InputRadio
          , HP.name "network"
          , HP.checked (state.network == net)
          , HE.onChange (\_ -> SelectNetwork net)
          ]
      , HH.text (" " <> label)
      ]

  renderModeTabs state =
    HH.article_
      [ HH.header_ [ HH.h2_ [ HH.text "Input" ] ]
      , HH.fieldset_
          [ HH.legend_ [ HH.text "Mode" ]
          , modeRadio state ByHash "By tx hash"
          , modeRadio state ByHex  "By CBOR hex"
          ]
      , renderBody state
      ]

  modeRadio state mode label =
    HH.label_
      [ HH.input
          [ HP.type_ HP.InputRadio
          , HP.name "mode"
          , HP.checked (state.mode == mode)
          , HE.onChange (\_ -> SelectMode mode)
          ]
      , HH.text (" " <> label)
      ]

  renderBody state = case state.mode of
    ByHash ->
      HH.div_
        [ HH.input
            [ HP.type_ HP.InputText
            , HP.placeholder "64-char tx hash"
            , HP.value state.txHash
            , HE.onValueInput SetTxHash
            ]
        , HH.button
            [ HP.disabled state.running
            , HE.onClick (\_ -> Decode)
            ]
            [ HH.text (if state.running then "Fetching & decoding..." else "Fetch & decode") ]
        ]
    ByHex ->
      HH.div_
        [ HH.textarea
            [ HP.value state.txHex
            , HP.placeholder "Conway tx CBOR hex..."
            , HP.rows 8
            , HE.onValueInput SetTxHex
            ]
        , HH.button
            [ HP.disabled state.running
            , HE.onClick (\_ -> Decode)
            ]
            [ HH.text (if state.running then "Decoding..." else "Decode") ]
        ]

  renderResult state =
    case state.fetchError of
      Just err ->
        HH.article
          [ HP.class_ (HH.ClassName "error") ]
          [ HH.strong_ [ HH.text "Fetch error: " ]
          , HH.text err
          ]
      Nothing -> case state.result of
        Nothing -> HH.text ""
        Just r ->
          HH.article_
            [ HH.header_
                [ HH.h2_ [ HH.text (if r.exitOk then "Decoded JSON" else "Error") ]
                , if r.exitOk
                    then
                      HH.button
                        [ HE.onClick (\_ -> Copy)
                        , HP.class_ (HH.ClassName "secondary")
                        ]
                        [ HH.text (if state.copied then "Copied!" else "Copy JSON") ]
                    else HH.text ""
                ]
            , HH.pre_ [ HH.text (Json.pretty r.stdout) ]
            , if r.stderr == "" then HH.text ""
              else
                HH.div_
                  [ HH.h3_ [ HH.text "stderr" ]
                  , HH.pre_ [ HH.text r.stderr ]
                  ]
            ]

  handleAction = case _ of
    SetBlockfrostKey s -> do
      H.modify_ _ { blockfrostKey = s }
      persist <- H.gets _.persistKeys
      when persist (liftEffect (Storage.setItem blockfrostKey s))
    SetKoiosBearer s -> do
      H.modify_ _ { koiosBearer = s }
      persist <- H.gets _.persistKeys
      when persist (liftEffect (Storage.setItem koiosKey s))
    SelectProvider p -> do
      H.modify_ _ { provider = p, fetchError = Nothing }
      liftEffect (Storage.setItem providerKey (Provider.providerName p))
    TogglePersist on -> do
      H.modify_ _ { persistKeys = on }
      liftEffect (Storage.setItem persistKeysStorageKey (if on then "true" else "false"))
      st <- H.get
      liftEffect
        if on
          then do
            Storage.setItem blockfrostKey st.blockfrostKey
            Storage.setItem koiosKey st.koiosBearer
          else do
            Storage.setItem blockfrostKey ""
            Storage.setItem koiosKey ""
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
                                then "Koios blocks anonymous browser requests by design. Sign up (free) at koios.rest/auth, paste the bearer token above, and retry."
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
