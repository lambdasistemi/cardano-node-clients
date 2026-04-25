module Main (main) where

import Prelude

import Data.Array as Array
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
import FFI.Inspector (InspectorResult, runInspectorRpc)
import FFI.Json (Browser, inspect, pretty, rpcBrowser, rpcInspection) as Json
import FFI.Storage as Storage
import Provider (Provider(..))
import Provider as Provider
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.VDom.Driver (runUI)
import Web.DOM.ParentNode (QuerySelector(..))

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
  app     <- HA.selectElement (QuerySelector "#app")
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
      mountTarget = case app of
        Just el -> el
        Nothing -> body
  runUI
    ( inspectorComponent
        { bf
        , koios: kOS
        , prov: initialProv
        , persistKeys: persistInitial
        }
    ) unit mountTarget

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
  , txCbor :: Maybe String
  , browser :: Maybe Json.Browser
  , browserNodes :: Array BrowserNode
  , expandedPaths :: Array String
  , running :: Boolean
  , copied :: Boolean
  , copiedPath :: Maybe String
  , browserPath :: String
  , fetchError :: Maybe String
  }

type BrowserNode =
  { path :: String
  , browser :: Json.Browser
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
  | CopyValue String String
  | BrowseJson String

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
        , txCbor: Nothing
        , browser: Nothing
        , browserNodes: []
        , expandedPaths: []
        , running: false
        , copied: false
        , copiedPath: Nothing
        , browserPath: "[]"
        , fetchError: Nothing
        }
    , render
    , eval: H.mkEval H.defaultEval { handleAction = handleAction }
    }
  where

  render state =
    HH.div
      [ classNames [ "app-shell" ] ]
      [ HH.section
          [ classNames [ "intro-strip" ] ]
          [ HH.div_
              [ HH.h1_ [ HH.text "Conway tx inspector" ]
              , HH.p_
                  [ HH.text
                      "Decode Conway transaction CBOR in the browser with the upstream Haskell ledger compiled to "
                  , HH.code_ [ HH.text "wasm32-wasi" ]
                  , HH.text "."
                  ]
              ]
          , HH.div
              [ classNames [ "tech-pills" ] ]
              [ HH.span_ [ HH.text "cardano-ledger-conway" ]
              , HH.span_ [ HH.text "cardano-ledger-binary" ]
              , HH.span_ [ HH.text "WASI" ]
              ]
          ]
      , HH.div
          [ classNames [ "workspace" ] ]
          [ renderProvider state
          , HH.div
              [ classNames [ "workspace-main" ] ]
              [ renderModeTabs state
              , renderResult state
              ]
          ]
      ]

  renderProvider state =
    HH.section
      [ classNames [ "panel", "provider-panel" ] ]
      [ HH.div
          [ classNames [ "panel-heading" ] ]
          [ HH.h2_ [ HH.text "Chain data" ]
          , HH.p_ [ HH.text "Credentials stay in memory unless persistence is enabled." ]
          ]
      , HH.fieldset
          [ classNames [ "control-group" ] ]
          [ HH.legend_ [ HH.text "Provider" ]
          , HH.div
              [ classNames [ "option-stack" ] ]
              [ providerRadio state Blockfrost "Blockfrost"
              , providerRadio state Koios      "Koios"
              ]
          ]
      , HH.div
          [ classNames [ "field-stack" ] ]
          [ case state.provider of
              Blockfrost ->
                HH.label
                  [ classNames [ "field-label" ] ]
                  [ HH.text "Blockfrost project ID"
                  , HH.a
                      [ HP.href "https://blockfrost.io/dashboard"
                      , HP.target "_blank"
                      , HP.rel "noopener noreferrer"
                      ]
                      [ HH.text "Dashboard" ]
                  ]
              Koios ->
                HH.label
                  [ classNames [ "field-label" ] ]
                  [ HH.text "Koios bearer token"
                  , HH.a
                      [ HP.href "https://koios.rest/auth/Auth.html"
                      , HP.target "_blank"
                      , HP.rel "noopener noreferrer"
                      ]
                      [ HH.text "Auth" ]
                  ]
          , case state.provider of
              Blockfrost ->
                HH.input
                  [ HP.type_ HP.InputPassword
                  , HP.placeholder "mainnet... / preprod... / preview..."
                  , HP.value state.blockfrostKey
                  , HE.onValueInput SetBlockfrostKey
                  ]
              Koios ->
                HH.input
                  [ HP.type_ HP.InputPassword
                  , HP.placeholder "eyJhbGciOi..."
                  , HP.value state.koiosBearer
                  , HE.onValueInput SetKoiosBearer
                  ]
          ]
      , HH.fieldset
          [ classNames [ "control-group" ] ]
          [ HH.legend_ [ HH.text "Network" ]
          , HH.div
              [ classNames [ "option-stack", "compact-options" ] ]
              [ networkRadio state Mainnet "mainnet"
              , networkRadio state Preprod "preprod"
              , networkRadio state Preview "preview"
              ]
          ]
      , renderPersistToggle state
      ]

  renderPersistToggle state =
    HH.div
      [ classNames [ "persist-block" ] ]
      [ HH.label
          [ classNames [ "switch-row" ] ]
          [ HH.input
              [ HP.type_ HP.InputCheckbox
              , HH.attr (HH.AttrName "role") "switch"
              , HP.checked state.persistKeys
              , HE.onChecked TogglePersist
              ]
          , HH.span_ [ HH.text "Persist API credentials" ]
          ]
      , HH.p
          [ classNames [ "warning-note" ] ]
          [ HH.strong_ [ HH.text "Warning: " ]
          , HH.text
              "when enabled, credentials are saved in localStorage in cleartext. When disabled, they stay in memory only."
          ]
      ]

  providerRadio state prov label =
    HH.label
      [ choiceClass (state.provider == prov) ]
      [ HH.input
          [ HP.type_ HP.InputRadio
          , HP.name "provider"
          , HP.checked (state.provider == prov)
          , HE.onChange (\_ -> SelectProvider prov)
          ]
      , HH.span
          [ classNames [ "choice-copy" ] ]
          [ HH.span
              [ classNames [ "choice-title" ] ]
              [ HH.text label ]
          ]
      ]

  networkRadio state net label =
    HH.label
      [ choiceClass (state.network == net) ]
      [ HH.input
          [ HP.type_ HP.InputRadio
          , HP.name "network"
          , HP.checked (state.network == net)
          , HE.onChange (\_ -> SelectNetwork net)
          ]
      , HH.span
          [ classNames [ "choice-title" ] ]
          [ HH.text label ]
      ]

  renderModeTabs state =
    HH.section
      [ classNames [ "panel", "input-panel" ] ]
      [ HH.div
          [ classNames [ "panel-heading" ] ]
          [ HH.h2_ [ HH.text "Input" ]
          , HH.p_ [ HH.text "Fetch by transaction hash or paste raw CBOR hex." ]
          ]
      , HH.fieldset
          [ classNames [ "control-group" ] ]
          [ HH.legend_ [ HH.text "Mode" ]
          , HH.div
              [ classNames [ "mode-options" ] ]
              [ modeRadio state ByHash "Tx hash"
              , modeRadio state ByHex  "CBOR hex"
              ]
          ]
      , renderBody state
      ]

  modeRadio state mode label =
    HH.label
      [ choiceClass (state.mode == mode) ]
      [ HH.input
          [ HP.type_ HP.InputRadio
          , HP.name "mode"
          , HP.checked (state.mode == mode)
          , HE.onChange (\_ -> SelectMode mode)
          ]
      , HH.span
          [ classNames [ "choice-title" ] ]
          [ HH.text label ]
      ]

  renderBody state = case state.mode of
    ByHash ->
      HH.div
        [ classNames [ "decode-form", "hash-form" ] ]
        [ HH.input
            [ HP.type_ HP.InputText
            , HP.placeholder "64-char tx hash"
            , HP.value state.txHash
            , HE.onValueInput SetTxHash
            ]
        , HH.button
            [ HP.disabled state.running
            , classNames [ "primary-action" ]
            , HE.onClick (\_ -> Decode)
            ]
            [ HH.text (if state.running then "Fetching..." else "Fetch and decode") ]
        ]
    ByHex ->
      HH.div
        [ classNames [ "decode-form" ] ]
        [ HH.textarea
            [ HP.value state.txHex
            , HP.placeholder "Conway tx CBOR hex..."
            , HP.rows 9
            , HE.onValueInput SetTxHex
            ]
        , HH.button
            [ HP.disabled state.running
            , classNames [ "primary-action" ]
            , HE.onClick (\_ -> Decode)
            ]
            [ HH.text (if state.running then "Decoding..." else "Decode") ]
        ]

  renderResult state =
    case state.fetchError of
      Just err ->
        HH.section
          [ classNames [ "panel", "result-panel", "error-panel" ] ]
          [ HH.div
              [ classNames [ "panel-heading" ] ]
              [ HH.h2_ [ HH.text "Fetch error" ] ]
          , HH.p_ [ HH.text err ]
          ]
      Nothing -> case state.result of
        Nothing ->
          HH.section
            [ classNames [ "panel", "result-panel", "empty-result" ] ]
            [ HH.div
                [ classNames [ "panel-heading" ] ]
                [ HH.h2_ [ HH.text "Decoded JSON" ] ]
            , HH.div
                [ classNames [ "empty-state" ] ]
                [ HH.text "No result yet." ]
            ]
        Just r ->
          let
            summary = Json.inspect r.stdout
          in
            HH.section
              [ classNames [ "panel", "result-panel" ] ]
              ( [ HH.div
                    [ classNames [ "panel-heading", "result-heading" ] ]
                    [ HH.div_
                        [ HH.h2_ [ HH.text (if r.exitOk then "Inspection" else "Error") ]
                        , if r.exitOk && summary.valid
                            then HH.p_ [ HH.text summary.title ]
                            else HH.text ""
                        ]
                    , if r.exitOk
                        then
                          HH.button
                            [ HE.onClick (\_ -> Copy)
                            , classNames [ "secondary-action" ]
                            ]
                            [ HH.text (if state.copied then "Copied" else "Copy JSON") ]
                        else HH.text ""
                    ]
                ]
              <> ( if r.exitOk && summary.valid
                     then renderInspection summary
                     else []
                 )
              <> renderBrowserMaybe state r.exitOk
              <> [ renderRawJson r.stdout ]
              <> renderStderr r.stderr
              )

  renderBrowserMaybe state exitOk =
    case state.browser of
      Just browser ->
        if exitOk && browser.valid then [ renderBrowser state browser ]
        else []
      Nothing -> []

  renderInspection summary =
    [ HH.div
        [ classNames [ "inspection-summary" ] ]
        [ HH.div
            [ classNames [ "metric-grid" ] ]
            (map renderMetric summary.metrics)
        ]
    ]

  renderBrowser state browser =
    HH.div
      [ classNames [ "json-browser" ] ]
      [ HH.div
          [ classNames [ "browser-heading" ] ]
          [ HH.div_
              [ HH.h3_ [ HH.text "Transaction browser" ]
              , HH.p_ [ HH.text browser.subtitle ]
              ]
          , HH.button
              [ HE.onClick (\_ -> CopyValue browser.currentPath browser.currentJson)
              , classNames [ "inline-action" ]
              ]
              [ HH.text
                  ( if state.copiedPath == Just browser.currentPath then
                      "Copied"
                    else
                      "Copy current"
                  )
              ]
          ]
      , HH.div
          [ classNames [ "browser-row-list" ] ]
          (renderTreeRows state browser)
      ]

  renderTreeRows state browser =
    if Array.null browser.rows then
      [ HH.div
          [ classNames [ "scalar-value" ] ]
          [ HH.code_ [ HH.text browser.currentJson ] ]
      ]
    else
      Array.concatMap (renderTreeRow state) browser.rows

  renderTreeRow state row =
    let
      expanded = isExpanded row.path state.expandedPaths
      child = browserAt row.path state.browserNodes
    in
      [ HH.div
          [ classNames
              ( if expanded then
                  [ "browser-row", "is-expanded" ]
                else
                  [ "browser-row" ]
              )
          ]
          [ HH.div
              [ classNames [ "browser-row-main" ] ]
              [ HH.div
                  [ classNames [ "browser-keyline" ] ]
                  [ HH.code_ [ HH.text row.label ]
                  , HH.span
                      [ classNames [ "kind-badge" ] ]
                      [ HH.text row.kind ]
                  ]
              , HH.div
                  [ classNames [ "browser-summary" ] ]
                  [ HH.text row.summary ]
              ]
          , HH.div
              [ classNames [ "browser-actions" ] ]
              [ if row.canDive then
                  HH.button
                    [ HE.onClick (\_ -> BrowseJson row.path)
                    , classNames [ "inline-action" ]
                    ]
                    [ HH.text (if expanded then "Close" else "Open") ]
                else HH.text ""
              , HH.button
                  [ HE.onClick (\_ -> CopyValue row.path row.copyValue)
                  , classNames [ "inline-action" ]
                  ]
                  [ HH.text
                      ( if state.copiedPath == Just row.path then
                          "Copied"
                        else
                          "Copy"
                      )
                  ]
              ]
          ]
      ] <> if expanded then
        [ HH.div
            [ classNames [ "browser-children" ] ]
            ( case child of
                Just browser ->
                  renderTreeRows state browser
                Nothing ->
                  [ HH.div
                      [ classNames [ "scalar-value" ] ]
                      [ HH.code_ [ HH.text "Loading..." ] ]
                  ]
            )
        ]
      else []

  isExpanded path paths =
    Array.elem path paths

  browserAt path nodes =
    _.browser <$> Array.find (\node -> node.path == path) nodes

  upsertBrowserNode path browser nodes =
    if Array.any (\node -> node.path == path) nodes then
      map
        ( \node ->
            if node.path == path then
              { path, browser }
            else
              node
        )
        nodes
    else
      Array.snoc nodes { path, browser }

  expandPath path paths =
    if Array.elem path paths then paths
    else Array.snoc paths path

  closePath path paths =
    Array.filter (_ /= path) paths

  rootBrowserNodes browser =
    [ { path: browser.currentPath, browser } ]

  renderMetric metric =
    HH.div
      [ classNames [ "metric-card" ] ]
      [ HH.span
          [ classNames [ "metric-label" ] ]
          [ HH.text metric.label ]
      , HH.strong_ [ HH.text metric.value ]
      ]

  renderRawJson stdout =
    HH.details
      [ classNames [ "raw-json-block" ] ]
      [ HH.summary_ [ HH.text "Raw JSON" ]
      , HH.pre_ [ HH.text (Json.pretty stdout) ]
      ]

  renderStderr stderr =
    if stderr == "" then []
    else
      [ HH.div
          [ classNames [ "stderr-block" ] ]
          [ HH.h3_ [ HH.text "stderr" ]
          , HH.pre_ [ HH.text stderr ]
          ]
      ]

  classNames :: forall r a. Array String -> HP.IProp (class :: String | r) a
  classNames names = HP.classes (map HH.ClassName names)

  choiceClass :: forall r a. Boolean -> HP.IProp (class :: String | r) a
  choiceClass selected =
    classNames
      ( if selected then
          [ "choice-option", "is-selected" ]
        else
          [ "choice-option" ]
      )

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
    SelectMode m -> H.modify_ _ { mode = m, fetchError = Nothing, copiedPath = Nothing }
    SelectNetwork n -> H.modify_ _ { network = n, fetchError = Nothing, copiedPath = Nothing }
    SetTxHash s -> H.modify_ _ { txHash = s, copied = false, copiedPath = Nothing, fetchError = Nothing }
    SetTxHex s -> H.modify_ _ { txHex = s, copied = false, copiedPath = Nothing, fetchError = Nothing }
    Decode -> do
      st <- H.get
      H.modify_
        _
          { running = true
          , result = Nothing
          , txCbor = Nothing
          , browser = Nothing
          , browserNodes = []
          , expandedPaths = []
          , copied = false
          , copiedPath = Nothing
          , browserPath = "[]"
          , fetchError = Nothing
          }
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
        Left err -> H.modify_ _ { running = false, fetchError = Just err, browserPath = "[]" }
        Right h -> do
          rpcResult <- H.liftAff (runInspectorRpc h "inspect" "[]")
          let
            inspectionResult = rpcResult { stdout = Json.rpcInspection rpcResult.stdout }
            browser = Json.rpcBrowser rpcResult.stdout
          H.modify_
            _
              { running = false
              , result = Just inspectionResult
              , txCbor = Just h
              , browser = if rpcResult.exitOk && browser.valid then Just browser else Nothing
              , browserNodes =
                  if rpcResult.exitOk && browser.valid then rootBrowserNodes browser
                  else []
              , expandedPaths = []
              , browserPath = browser.currentPath
              }
    Copy -> do
      mr <- H.gets _.result
      case mr of
        Nothing -> pure unit
        Just r -> do
          H.liftAff (Clipboard.copy (Json.pretty r.stdout))
          H.modify_ _ { copied = true, copiedPath = Nothing }
    CopyValue path value -> do
      H.liftAff (Clipboard.copy value)
      H.modify_ _ { copied = false, copiedPath = Just path }
    BrowseJson path ->
      do
        st <- H.get
        if isExpanded path st.expandedPaths then
          H.modify_ _ { expandedPaths = closePath path st.expandedPaths, copiedPath = Nothing }
        else case st.txCbor of
          Nothing ->
            H.modify_ _ { browserPath = path, copiedPath = Nothing }
          Just txCbor -> do
            H.modify_ _ { browserPath = path, copiedPath = Nothing }
            rpcResult <- H.liftAff (runInspectorRpc txCbor "browse" path)
            let browser = Json.rpcBrowser rpcResult.stdout
            H.modify_
              _
                { browserNodes =
                    if rpcResult.exitOk && browser.valid then
                      upsertBrowserNode path browser st.browserNodes
                    else
                      st.browserNodes
                , expandedPaths =
                    if rpcResult.exitOk && browser.valid then
                      expandPath path st.expandedPaths
                    else
                      st.expandedPaths
                , browserPath = browser.currentPath
                , fetchError =
                    if rpcResult.exitOk && browser.valid then Nothing
                    else Just (if rpcResult.stderr == "" then "Haskell RPC browse failed." else rpcResult.stderr)
                }
