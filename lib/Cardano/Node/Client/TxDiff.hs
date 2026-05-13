{-# LANGUAGE TypeApplications #-}

{- |
Module      : Cardano.Node.Client.TxDiff
Description : Structural transaction diff primitives.

This module contains the render-independent diff core used by the transaction
diff feature. The central rule is equality first: paired values are compared
before any child projection is requested.
-}
module Cardano.Node.Client.TxDiff (
    DiffChange (..),
    DiffNode (..),
    DiffPlan (..),
    DiffPath (..),
    DiffProjection (..),
    OpenValue (..),
    diffConwayTx,
    diffOpenValue,
    diffWith,
) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Lens.Micro ((^.))

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address (
    AccountAddress,
    Addr,
    Withdrawals (..),
    serialiseAddr,
 )
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.Scripts.Data (Datum)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body (
    collateralInputsTxBodyL,
    feeTxBodyL,
    inputsTxBodyL,
    mintTxBodyL,
    outputsTxBodyL,
    referenceInputsTxBodyL,
    reqSignerHashesTxBodyL,
    totalCollateralTxBodyL,
    vldtTxBodyL,
    withdrawalsTxBodyL,
 )
import Cardano.Ledger.Api.Tx.Out (
    TxOut,
    addrTxOutL,
    coinTxOutL,
    datumTxOutL,
    referenceScriptTxOutL,
 )
import Cardano.Ledger.BaseTypes (StrictMaybe (..), TxIx (..))
import Cardano.Ledger.Binary (serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (Script, eraProtVerLow)
import Cardano.Ledger.Hashes (ScriptHash (..), extractHash)
import Cardano.Ledger.Keys (
    KeyHash (..),
    KeyRole (Guard),
 )
import Cardano.Ledger.Mary.Value (
    AssetName (..),
    MultiAsset (..),
    PolicyID (..),
 )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.Ledger (ConwayTx)
import Cardano.Slotting.Slot (SlotNo (..))

newtype DiffPath = DiffPath [Text]
    deriving stock (Eq, Show)

data DiffNode = DiffNode DiffPath DiffChange
    deriving stock (Eq, Show)

data DiffChange
    = DiffSame (Maybe Aeson.Value)
    | DiffChanged Aeson.Value Aeson.Value
    | DiffObject
        (Map Text (Maybe Aeson.Value))
        (Map Text DiffNode)
        (Map Text Aeson.Value)
        (Map Text Aeson.Value)
    | DiffArray
        [(Int, Maybe Aeson.Value)]
        [(Int, DiffNode)]
        [(Int, Aeson.Value)]
        [(Int, Aeson.Value)]
    deriving stock (Eq, Show)

data DiffPlan a = DiffPlan
    { diffEqual :: a -> a -> Bool
    , diffSummary :: a -> Maybe Aeson.Value
    , diffProject :: a -> DiffProjection a
    }

data DiffProjection a
    = DiffAtomic Aeson.Value
    | DiffObjectChildren (Map Text a)
    | DiffArrayChildren [a]

data OpenValue
    = OpenObject (Map Text OpenValue)
    | OpenArray [OpenValue]
    | OpenInteger Integer
    | OpenText Text
    | OpenBytes Text
    deriving stock (Eq, Show)

data ConwayDiffValue
    = ConwayTxValue ConwayTx
    | ConwayBodyValue ConwayTx
    | ConwayCoinValue Coin
    | ConwayStrictMaybeCoinValue (StrictMaybe Coin)
    | ConwayInputsValue [TxIn]
    | ConwayTxInValue TxIn
    | ConwayKeyHashesValue [KeyHash Guard]
    | ConwayKeyHashValue (KeyHash Guard)
    | ConwayMintValue MultiAsset
    | ConwayAssetQuantitiesValue (Map AssetName Integer)
    | ConwayIntegerValue Integer
    | ConwayWithdrawalsValue Withdrawals
    | ConwayValidityIntervalValue ValidityInterval
    | ConwaySlotBoundValue (StrictMaybe SlotNo)
    | ConwayOutputsValue [TxOut ConwayEra]
    | ConwayTxOutValue (TxOut ConwayEra)
    | ConwayAddressValue Addr
    | ConwayDatumValue (Datum ConwayEra)
    | ConwayReferenceScriptValue (StrictMaybe (Script ConwayEra))

diffConwayTx :: ConwayTx -> ConwayTx -> DiffNode
diffConwayTx left right =
    diffWith conwayDiffPlan (ConwayTxValue left) (ConwayTxValue right)

diffOpenValue :: OpenValue -> OpenValue -> DiffNode
diffOpenValue =
    diffWith openValuePlan

diffWith :: DiffPlan a -> a -> a -> DiffNode
diffWith plan =
    diffAt plan (DiffPath [])

diffAt :: DiffPlan a -> DiffPath -> a -> a -> DiffNode
diffAt plan path left right
    | diffEqual plan left right = DiffNode path (DiffSame (diffSummary plan left))
    | otherwise =
        case (diffProject plan left, diffProject plan right) of
            (DiffObjectChildren leftChildren, DiffObjectChildren rightChildren) ->
                diffObjectChildren plan path leftChildren rightChildren
            (DiffArrayChildren leftChildren, DiffArrayChildren rightChildren) ->
                diffArrayChildren plan path leftChildren rightChildren
            (leftProjection, rightProjection) ->
                DiffNode path $
                    DiffChanged
                        (projectionValue plan leftProjection)
                        (projectionValue plan rightProjection)

diffObjectChildren ::
    DiffPlan a ->
    DiffPath ->
    Map Text a ->
    Map Text a ->
    DiffNode
diffObjectChildren plan path leftChildren rightChildren =
    DiffNode path (DiffObject common changed onlyA onlyB)
  where
    keys =
        Map.keysSet leftChildren <> Map.keysSet rightChildren
    (common, changed, onlyA, onlyB) =
        foldr classify (Map.empty, Map.empty, Map.empty, Map.empty) keys

    classify key (commonAcc, changedAcc, onlyAAcc, onlyBAcc) =
        case (Map.lookup key leftChildren, Map.lookup key rightChildren) of
            (Just left, Just right)
                | diffEqual plan left right ->
                    ( Map.insert key (diffSummary plan left) commonAcc
                    , changedAcc
                    , onlyAAcc
                    , onlyBAcc
                    )
                | otherwise ->
                    ( commonAcc
                    , Map.insert key (diffAt plan (path </> key) left right) changedAcc
                    , onlyAAcc
                    , onlyBAcc
                    )
            (Just left, Nothing) ->
                ( commonAcc
                , changedAcc
                , Map.insert key (valueOf plan left) onlyAAcc
                , onlyBAcc
                )
            (Nothing, Just right) ->
                ( commonAcc
                , changedAcc
                , onlyAAcc
                , Map.insert key (valueOf plan right) onlyBAcc
                )
            (Nothing, Nothing) ->
                (commonAcc, changedAcc, onlyAAcc, onlyBAcc)

diffArrayChildren :: DiffPlan a -> DiffPath -> [a] -> [a] -> DiffNode
diffArrayChildren plan path leftChildren rightChildren =
    DiffNode path (DiffArray common changed onlyA onlyB)
  where
    paired =
        zip [0 :: Int ..] (zip leftChildren rightChildren)
    common =
        [ (index, diffSummary plan left)
        | (index, (left, right)) <- paired
        , diffEqual plan left right
        ]
    changed =
        [ (index, diffAt plan (path </> Text.pack (show index)) left right)
        | (index, (left, right)) <- paired
        , not (diffEqual plan left right)
        ]
    onlyA =
        [ (index, valueOf plan left)
        | (index, left) <-
            drop (length rightChildren) (zip [0 :: Int ..] leftChildren)
        ]
    onlyB =
        [ (index, valueOf plan right)
        | (index, right) <-
            drop (length leftChildren) (zip [0 :: Int ..] rightChildren)
        ]

valueOf :: DiffPlan a -> a -> Aeson.Value
valueOf plan =
    projectionValue plan . diffProject plan

projectionValue :: DiffPlan a -> DiffProjection a -> Aeson.Value
projectionValue _ (DiffAtomic value) =
    value
projectionValue plan (DiffObjectChildren children) =
    objectValue
        [ (key, valueOf plan child)
        | (key, child) <- Map.toAscList children
        ]
projectionValue plan (DiffArrayChildren children) =
    Aeson.toJSON (map (valueOf plan) children)

objectValue :: [(Text, Aeson.Value)] -> Aeson.Value
objectValue fields =
    Aeson.Object $
        KeyMap.fromList
            [ (Key.fromText key, value)
            | (key, value) <- fields
            ]

(</>) :: DiffPath -> Text -> DiffPath
DiffPath segments </> segment =
    DiffPath (segments <> [segment])

openValuePlan :: DiffPlan OpenValue
openValuePlan =
    DiffPlan
        { diffEqual = (==)
        , diffSummary = openValueSummary
        , diffProject = openValueProjection
        }

conwayDiffPlan :: DiffPlan ConwayDiffValue
conwayDiffPlan =
    DiffPlan
        { diffEqual = conwayDiffEqual
        , diffSummary = conwayDiffSummary
        , diffProject = conwayDiffProjection
        }

conwayDiffEqual :: ConwayDiffValue -> ConwayDiffValue -> Bool
conwayDiffEqual (ConwayTxValue left) (ConwayTxValue right) =
    left == right
conwayDiffEqual (ConwayBodyValue left) (ConwayBodyValue right) =
    left ^. bodyTxL == right ^. bodyTxL
conwayDiffEqual (ConwayCoinValue left) (ConwayCoinValue right) =
    left == right
conwayDiffEqual
    (ConwayStrictMaybeCoinValue left)
    (ConwayStrictMaybeCoinValue right) =
        left == right
conwayDiffEqual (ConwayInputsValue left) (ConwayInputsValue right) =
    left == right
conwayDiffEqual (ConwayTxInValue left) (ConwayTxInValue right) =
    left == right
conwayDiffEqual (ConwayKeyHashesValue left) (ConwayKeyHashesValue right) =
    left == right
conwayDiffEqual (ConwayKeyHashValue left) (ConwayKeyHashValue right) =
    left == right
conwayDiffEqual (ConwayMintValue left) (ConwayMintValue right) =
    left == right
conwayDiffEqual
    (ConwayAssetQuantitiesValue left)
    (ConwayAssetQuantitiesValue right) =
        left == right
conwayDiffEqual (ConwayIntegerValue left) (ConwayIntegerValue right) =
    left == right
conwayDiffEqual (ConwayWithdrawalsValue left) (ConwayWithdrawalsValue right) =
    left == right
conwayDiffEqual (ConwayValidityIntervalValue left) (ConwayValidityIntervalValue right) =
    left == right
conwayDiffEqual (ConwaySlotBoundValue left) (ConwaySlotBoundValue right) =
    left == right
conwayDiffEqual (ConwayOutputsValue left) (ConwayOutputsValue right) =
    left == right
conwayDiffEqual (ConwayTxOutValue left) (ConwayTxOutValue right) =
    left == right
conwayDiffEqual (ConwayAddressValue left) (ConwayAddressValue right) =
    left == right
conwayDiffEqual (ConwayDatumValue left) (ConwayDatumValue right) =
    left == right
conwayDiffEqual
    (ConwayReferenceScriptValue left)
    (ConwayReferenceScriptValue right) =
        left == right
conwayDiffEqual _ _ =
    False

conwayDiffSummary :: ConwayDiffValue -> Maybe Aeson.Value
conwayDiffSummary (ConwayCoinValue coin) =
    Just (coinValue coin)
conwayDiffSummary (ConwayStrictMaybeCoinValue coin) =
    Just (strictMaybeCoinValue coin)
conwayDiffSummary (ConwayInputsValue inputs) =
    Just (inputsValue inputs)
conwayDiffSummary (ConwayTxInValue txIn) =
    Just (txInValue txIn)
conwayDiffSummary (ConwayKeyHashesValue keyHashes) =
    Just (keyHashesValue keyHashes)
conwayDiffSummary (ConwayKeyHashValue keyHash) =
    Just (keyHashValue keyHash)
conwayDiffSummary (ConwayMintValue mint) =
    Just (mintValue mint)
conwayDiffSummary (ConwayAssetQuantitiesValue assets) =
    Just (assetQuantitiesValue assets)
conwayDiffSummary (ConwayIntegerValue quantity) =
    Just (Aeson.toJSON quantity)
conwayDiffSummary (ConwayWithdrawalsValue withdrawals) =
    Just (withdrawalsValue withdrawals)
conwayDiffSummary (ConwayValidityIntervalValue validity) =
    Just (validityIntervalValue validity)
conwayDiffSummary (ConwaySlotBoundValue slotBound) =
    Just (slotBoundValue slotBound)
conwayDiffSummary (ConwayOutputsValue outputs) =
    Just (Aeson.toJSON (map txOutValue outputs))
conwayDiffSummary (ConwayTxOutValue output) =
    Just (txOutValue output)
conwayDiffSummary (ConwayAddressValue address) =
    Just (addressValue address)
conwayDiffSummary (ConwayDatumValue datum) =
    Just (datumValue datum)
conwayDiffSummary (ConwayReferenceScriptValue referenceScript) =
    Just (referenceScriptValue referenceScript)
conwayDiffSummary (ConwayTxValue _) =
    Nothing
conwayDiffSummary (ConwayBodyValue _) =
    Nothing

conwayDiffProjection :: ConwayDiffValue -> DiffProjection ConwayDiffValue
conwayDiffProjection (ConwayTxValue tx) =
    DiffObjectChildren (Map.singleton "body" (ConwayBodyValue tx))
conwayDiffProjection (ConwayBodyValue tx) =
    DiffObjectChildren $
        Map.fromList
            [
                ( "collateralInputs"
                , ConwayInputsValue $
                    Set.toAscList (tx ^. bodyTxL . collateralInputsTxBodyL)
                )
            ,
                ( "fee"
                , ConwayCoinValue (tx ^. bodyTxL . feeTxBodyL)
                )
            ,
                ( "inputs"
                , ConwayInputsValue $
                    Set.toAscList (tx ^. bodyTxL . inputsTxBodyL)
                )
            ,
                ( "mint"
                , ConwayMintValue (tx ^. bodyTxL . mintTxBodyL)
                )
            ,
                ( "referenceInputs"
                , ConwayInputsValue $
                    Set.toAscList (tx ^. bodyTxL . referenceInputsTxBodyL)
                )
            ,
                ( "requiredSigners"
                , ConwayKeyHashesValue $
                    Set.toAscList (tx ^. bodyTxL . reqSignerHashesTxBodyL)
                )
            ,
                ( "totalCollateral"
                , ConwayStrictMaybeCoinValue $
                    tx ^. bodyTxL . totalCollateralTxBodyL
                )
            ,
                ( "validityInterval"
                , ConwayValidityIntervalValue (tx ^. bodyTxL . vldtTxBodyL)
                )
            ,
                ( "withdrawals"
                , ConwayWithdrawalsValue (tx ^. bodyTxL . withdrawalsTxBodyL)
                )
            ,
                ( "outputs"
                , ConwayOutputsValue (toList (tx ^. bodyTxL . outputsTxBodyL))
                )
            ]
conwayDiffProjection (ConwayCoinValue coin) =
    DiffAtomic (coinValue coin)
conwayDiffProjection (ConwayStrictMaybeCoinValue coin) =
    DiffAtomic (strictMaybeCoinValue coin)
conwayDiffProjection (ConwayInputsValue inputs) =
    DiffArrayChildren (map ConwayTxInValue inputs)
conwayDiffProjection (ConwayTxInValue txIn) =
    DiffAtomic (txInValue txIn)
conwayDiffProjection (ConwayKeyHashesValue keyHashes) =
    DiffArrayChildren (map ConwayKeyHashValue keyHashes)
conwayDiffProjection (ConwayKeyHashValue keyHash) =
    DiffAtomic (keyHashValue keyHash)
conwayDiffProjection (ConwayMintValue mint) =
    DiffObjectChildren (mintChildren mint)
conwayDiffProjection (ConwayAssetQuantitiesValue assets) =
    DiffObjectChildren (assetQuantityChildren assets)
conwayDiffProjection (ConwayIntegerValue quantity) =
    DiffAtomic (Aeson.toJSON quantity)
conwayDiffProjection (ConwayWithdrawalsValue withdrawals) =
    DiffObjectChildren (withdrawalChildren withdrawals)
conwayDiffProjection (ConwayValidityIntervalValue validity) =
    DiffObjectChildren $
        Map.fromList
            [
                ( "invalidBefore"
                , ConwaySlotBoundValue (invalidBefore validity)
                )
            ,
                ( "invalidHereafter"
                , ConwaySlotBoundValue (invalidHereafter validity)
                )
            ]
conwayDiffProjection (ConwaySlotBoundValue slotBound) =
    DiffAtomic (slotBoundValue slotBound)
conwayDiffProjection (ConwayOutputsValue outputs) =
    DiffArrayChildren (map ConwayTxOutValue outputs)
conwayDiffProjection (ConwayTxOutValue output) =
    DiffObjectChildren $
        Map.fromList
            [
                ( "address"
                , ConwayAddressValue (output ^. addrTxOutL)
                )
            ,
                ( "coin"
                , ConwayCoinValue (output ^. coinTxOutL)
                )
            ,
                ( "datum"
                , ConwayDatumValue (output ^. datumTxOutL)
                )
            ,
                ( "referenceScript"
                , ConwayReferenceScriptValue (output ^. referenceScriptTxOutL)
                )
            ]
conwayDiffProjection (ConwayAddressValue address) =
    DiffAtomic (addressValue address)
conwayDiffProjection (ConwayDatumValue datum) =
    DiffAtomic (datumValue datum)
conwayDiffProjection (ConwayReferenceScriptValue referenceScript) =
    DiffAtomic (referenceScriptValue referenceScript)

coinValue :: Coin -> Aeson.Value
coinValue (Coin lovelace) =
    Aeson.object ["lovelace" .= lovelace]

strictMaybeCoinValue :: StrictMaybe Coin -> Aeson.Value
strictMaybeCoinValue SNothing =
    Aeson.Null
strictMaybeCoinValue (SJust coin) =
    coinValue coin

inputsValue :: [TxIn] -> Aeson.Value
inputsValue inputs =
    Aeson.toJSON (map txInValue inputs)

txInValue :: TxIn -> Aeson.Value
txInValue (TxIn (TxId safeHash) (TxIx index)) =
    Aeson.object
        [ "txId" .= hexText (hashToBytes (extractHash safeHash))
        , "index" .= index
        ]

keyHashesValue :: [KeyHash Guard] -> Aeson.Value
keyHashesValue keyHashes =
    Aeson.toJSON (map keyHashValue keyHashes)

keyHashValue :: KeyHash Guard -> Aeson.Value
keyHashValue (KeyHash keyHash) =
    Aeson.String (hexText (hashToBytes keyHash))

mintValue :: MultiAsset -> Aeson.Value
mintValue mint =
    objectValue
        [ (policyIdKey policyId, assetQuantitiesValue assets)
        | (policyId, assets) <- mintEntries mint
        ]

mintChildren :: MultiAsset -> Map Text ConwayDiffValue
mintChildren mint =
    Map.fromList
        [ (policyIdKey policyId, ConwayAssetQuantitiesValue assets)
        | (policyId, assets) <- mintEntries mint
        ]

mintEntries :: MultiAsset -> [(PolicyID, Map AssetName Integer)]
mintEntries (MultiAsset policies) =
    Map.toAscList policies

assetQuantitiesValue :: Map AssetName Integer -> Aeson.Value
assetQuantitiesValue assets =
    objectValue
        [ (assetNameKey assetName, Aeson.toJSON quantity)
        | (assetName, quantity) <- Map.toAscList assets
        ]

assetQuantityChildren :: Map AssetName Integer -> Map Text ConwayDiffValue
assetQuantityChildren assets =
    Map.fromList
        [ (assetNameKey assetName, ConwayIntegerValue quantity)
        | (assetName, quantity) <- Map.toAscList assets
        ]

policyIdKey :: PolicyID -> Text
policyIdKey (PolicyID (ScriptHash policyHash)) =
    hexText (hashToBytes policyHash)

assetNameKey :: AssetName -> Text
assetNameKey (AssetName bytes) =
    hexText (SBS.fromShort bytes)

withdrawalsValue :: Withdrawals -> Aeson.Value
withdrawalsValue withdrawals =
    objectValue
        [ (rewardAccountKey rewardAccount, coinValue coin)
        | (rewardAccount, coin) <- withdrawalEntries withdrawals
        ]

withdrawalChildren :: Withdrawals -> Map Text ConwayDiffValue
withdrawalChildren withdrawals =
    Map.fromList
        [ (rewardAccountKey rewardAccount, ConwayCoinValue coin)
        | (rewardAccount, coin) <- withdrawalEntries withdrawals
        ]

withdrawalEntries :: Withdrawals -> [(AccountAddress, Coin)]
withdrawalEntries (Withdrawals withdrawals) =
    Map.toAscList withdrawals

rewardAccountKey :: AccountAddress -> Text
rewardAccountKey rewardAccount =
    hexText (serialize' (eraProtVerLow @ConwayEra) rewardAccount)

validityIntervalValue :: ValidityInterval -> Aeson.Value
validityIntervalValue validity =
    Aeson.object
        [ "invalidBefore" .= slotBoundValue (invalidBefore validity)
        , "invalidHereafter" .= slotBoundValue (invalidHereafter validity)
        ]

slotBoundValue :: StrictMaybe SlotNo -> Aeson.Value
slotBoundValue SNothing =
    Aeson.Null
slotBoundValue (SJust (SlotNo slot)) =
    Aeson.toJSON slot

txOutValue :: TxOut ConwayEra -> Aeson.Value
txOutValue output =
    Aeson.object
        [ "address" .= addressValue (output ^. addrTxOutL)
        , "coin" .= coinValue (output ^. coinTxOutL)
        , "datum" .= datumValue (output ^. datumTxOutL)
        , "referenceScript"
            .= referenceScriptValue (output ^. referenceScriptTxOutL)
        ]

addressValue :: Addr -> Aeson.Value
addressValue address =
    Aeson.object ["bytes" .= hexText (serialiseAddr address)]

datumValue :: Datum ConwayEra -> Aeson.Value
datumValue datum =
    Aeson.object
        [ "cbor" .= hexText (serialize' (eraProtVerLow @ConwayEra) datum)
        ]

referenceScriptValue :: StrictMaybe (Script ConwayEra) -> Aeson.Value
referenceScriptValue SNothing =
    Aeson.Null
referenceScriptValue (SJust script) =
    Aeson.object
        [ "cbor" .= hexText (serialize' (eraProtVerLow @ConwayEra) script)
        ]

hexText :: ByteString -> Text
hexText =
    TextEncoding.decodeUtf8 . Base16.encode

openValueSummary :: OpenValue -> Maybe Aeson.Value
openValueSummary (OpenInteger value) =
    Just (Aeson.Number (fromInteger value))
openValueSummary (OpenText value) =
    Just (Aeson.String value)
openValueSummary (OpenBytes value) =
    Just (Aeson.object ["bytes" .= value])
openValueSummary (OpenObject _) =
    Nothing
openValueSummary (OpenArray _) =
    Nothing

openValueProjection :: OpenValue -> DiffProjection OpenValue
openValueProjection (OpenObject fields) =
    DiffObjectChildren fields
openValueProjection (OpenArray values) =
    DiffArrayChildren values
openValueProjection (OpenInteger value) =
    DiffAtomic (Aeson.Number (fromInteger value))
openValueProjection (OpenText value) =
    DiffAtomic (Aeson.String value)
openValueProjection (OpenBytes value) =
    DiffAtomic (Aeson.object ["bytes" .= value])
