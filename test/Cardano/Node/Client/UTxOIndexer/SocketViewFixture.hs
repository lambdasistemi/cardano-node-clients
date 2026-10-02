{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Cardano.Node.Client.UTxOIndexer.SocketViewFixture
Description : Independent ledger-output history for socket read views
License     : Apache-2.0

Produces bytes and facts with the ledger; folds create/spend/rollback into
pure maps without production extraction or storage reads. References have
fixed outputs across forks. Corrupt-store refusal tests use a separate domain.
-}
module Cardano.Node.Client.UTxOIndexer.SocketViewFixture (
    Point,
    State,
    Action (..),
    Change (..),
    Produced (..),
    backends,
    withBackend,
    drive,
    history,
    script,
    fixedOutputDomain,
    firstState,
    queries,
    queryValue,
    batchLine,
    expected,
    expectedView,
    wirePoint,
    wireTxIn,
    addrA,
    addrB,
    policyA,
    policyB,
    tx,
    blockHash,
    produced,
    disclosure,
    readyFixed,
    withServer,
    seed,
) where

import Cardano.Crypto.Hash.Class (Hash (UnsafeHash), hashToBytes)
import Cardano.Ledger.Address (Addr (..), serialiseAddr)
import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Binary (DecoderError, decCBOR, decodeFullDecoder, serialize')
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.Credential (Credential (KeyHashObj), StakeReference (StakeRefNull))
import Cardano.Ledger.Hashes (ScriptHash (..), extractHash, originalBytes, unsafeMakeSafeHash)
import Cardano.Ledger.Keys (KeyHash (..))
import Cardano.Ledger.Mary.Value qualified as Mary
import Cardano.Ledger.Plutus.Data (Datum (..), makeBinaryData)
import Cardano.Node.Client.N2C.Reconnect (UpstreamStatus (..))
import Cardano.Node.Client.UTxOIndexer.Columns (Cols)
import Cardano.Node.Client.UTxOIndexer.Disclosure (AddressCoverage (..), Coverage (..), CoverageStart (..), Disclosure (..))
import Cardano.Node.Client.UTxOIndexer.Indexer (AssetMatch (..), IndexedView (..), IndexerHandle (..), ReadQuery (..), ReadResult (..), UtxoOp (..), withInMemoryIndexerRunner, withRocksDBIndexerRunner)
import Cardano.Node.Client.UTxOIndexer.Server (ReadyStatus (..), runServer)
import Cardano.Node.Client.UTxOIndexer.Types (Address (..), AssetName (..), BlockHash (..), PolicyId (..), SlotNo (..), TxIn (..), TxOut (..))
import Cardano.Node.Client.UTxOIndexer.WireClient (BatchAnswer (..), BatchResult (..), Match (..), encodeLine, hex, withSocketServer)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.ByteString.Short qualified as SBS
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Data.Word (Word64, Word8)
import Database.KV.Transaction (RunTransaction)
import Lens.Micro ((&), (.~), (^.))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

-- | Full point, including hash, which distinguishes same-slot forks.
type Point = (SlotNo, BlockHash)

-- | Live references with producer facts and original creation point.
type State = Map TxIn (Produced, Point)

-- | A ledger-reachable history step (rollback precedes a competing fork).
data Action = Apply Word64 BlockHash [Change] | Rollback Word64

-- | Moves spend an old reference and create a distinct one.
data Change = Create TxIn Produced | Spend TxIn

-- | Facts decoded from the ledger output, independent of server/storage.
data Produced = Produced
    { outAddress :: Address
    , outBytes :: TxOut
    , outAssets :: [(ByteString, ByteString, Word64)]
    , outDatum :: KM.KeyMap Aeson.Value
    }
    deriving stock (Eq, Show)

-- | Both real storage implementations.
backends :: [String]
backends = ["in-memory", "RocksDB"]

-- | Bracket one real backend with its low-level corruption test runner.
withBackend :: String -> (forall cf op. IndexerHandle -> RunTransaction IO cf Cols op -> IO a) -> IO a
withBackend "in-memory" = withInMemoryIndexerRunner
withBackend _ = \action -> withSystemTempDirectory "socket-view" $ \dir -> withRocksDBIndexerRunner (dir </> "db") action

-- | Apply the same producer outputs that the model folds.
drive :: IndexerHandle -> Action -> IO ()
drive h (Rollback s) = rollbackTo h (SlotNo s)
drive h (Apply s bh changes) = applyAtSlot h (SlotNo s) bh (map op changes)
  where
    op (Spend t) = UtxoSpend t
    op (Create t p) = UtxoCreate t (outAddress p) (outBytes p)

-- | Pure states at every acknowledged point, including rollback/fork.
history :: [Action] -> [(Point, State)]
history = go Map.empty
  where
    go _ [] = []
    go past (a : rest) =
        let next = case a of
                Rollback s -> Map.filterWithKey (\k _ -> k <= s) past
                Apply s bh changes ->
                    let old = maybe Map.empty (snd . snd) (Map.lookupMax past)
                        update st (Spend t) = Map.delete t st
                        update st (Create t p) = Map.insert t (p, (SlotNo s, bh)) st
                     in Map.insert s (bh, foldl update old changes) past
            current = case Map.lookupMax next of
                Just (s, (bh, st)) -> ((SlotNo s, bh), st)
                Nothing -> error "fixture rolls behind its first point"
         in current : go next rest

-- | Reject reuse of a reference with a different address or serialized output.
fixedOutputDomain :: [Action] -> Bool
fixedOutputDomain actions = all identical (Map.elems outputs)
  where
    outputs = Map.fromListWith (<>) [(t, [(outAddress p, outBytes p)]) | Apply _ _ cs <- actions, Create t p <- cs]
    identical [] = False
    identical (p : ps) = all (== p) ps

{- | Produce/serialize/decode an enterprise-address Conway output.
Datum choices 0/1/2 are none/hash/inline; expected facts come from decoding.
-}
produced :: Word8 -> Word64 -> Int -> Produced
produced a quantity datumKind = Produced address (TxOut bytes) assets datum
  where
    addr = Addr Testnet (KeyHashObj (KeyHash (UnsafeHash (SBS.toShort (BS.replicate 28 a))))) StakeRefNull
    value =
        Mary.valueFromList
            (Coin 5_000_000_000)
            [ (ledgerPolicy p, Mary.AssetName (SBS.toShort n), toInteger q)
            | (p, n, q) <-
                [(unPolicyId policyA, "tok", quantity), (unPolicyId policyB, "tok", quantity + 1), (unPolicyId policyA, "", 2), (unPolicyId policyA, "\xFF\xFE", 3), (unPolicyId policyA, BS.replicate 32 0xEE, 4)]
            ]
    ledgerPolicy p = Mary.PolicyID (ScriptHash (UnsafeHash (SBS.toShort p)))
    base = mkBasicTxOut @ConwayEra addr value
    out = case datumKind of
        1 -> base & datumTxOutL .~ DatumHash (unsafeMakeSafeHash (UnsafeHash (SBS.toShort (BS.replicate 32 a))))
        2 -> base & datumTxOutL .~ Datum (either error id (makeBinaryData (SBS.toShort (BS.pack [0x18, a]))))
        _ -> base
    bytes = serialize' (Ledger.eraProtVerLow @ConwayEra) out
    decodedOut = either (error . show) id (decodeFullDecoder (Ledger.eraProtVerLow @ConwayEra) "fixture" decCBOR (LBS.fromStrict bytes) :: Either DecoderError (Ledger.TxOut ConwayEra))
    address = Address (serialiseAddr (decodedOut ^. Ledger.addrTxOutL))
    assets =
        let Mary.MaryValue _ multi = decodedOut ^. Ledger.valueTxOutL
         in [(SBS.fromShort p, SBS.fromShort n, fromInteger q) | (Mary.PolicyID (ScriptHash (UnsafeHash p)), Mary.AssetName n, q) <- Mary.flattenMultiAsset multi, q > 0]
    datum = case decodedOut ^. datumTxOutL of
        NoDatum -> KM.fromList [("kind", "none")]
        DatumHash h -> KM.fromList [("kind", "hash"), ("hash", Aeson.String (hex (hashToBytes (extractHash h))))]
        Datum d -> KM.fromList [("kind", "inline"), ("cbor", Aeson.String (hex (originalBytes d)))]

-- | Two producer addresses.
addrA, addrB :: Address
addrA = outAddress (produced 0xA1 7 0)
addrB = outAddress (produced 0xB2 8 1)

-- | Same names under distinct policies.
policyA, policyB :: PolicyId
policyA = PolicyId (BS.replicate 28 0xAB)
policyB = PolicyId (BS.replicate 28 0xCD)

-- | A distinct synthetic reference; no reference ever changes output.
tx :: Word8 -> TxIn
tx n = TxIn (BS.replicate 32 n) 0

-- | Distinct block hash bytes from the history producer.
blockHash :: Word8 -> BlockHash
blockHash = BlockHash . BS.replicate 32

-- | Mixed queries, duplicates, empty/non-UTF8/maximal names and no matches.
queries :: NonEmpty ReadQuery
queries =
    AddressQuery addrA
        :| [ AssetQuery policyA (AssetName "tok")
           , AddressQuery addrB
           , AssetQuery policyB (AssetName "tok")
           , AddressQuery addrA
           , AssetQuery policyA (AssetName "tok")
           , AssetQuery policyA (AssetName "")
           , AssetQuery policyA (AssetName "\xFF\xFE")
           , AssetQuery policyA (AssetName (BS.replicate 32 0xEE))
           , AddressQuery (Address "absent")
           , AssetQuery policyA (AssetName "absent")
           ]

-- | A request query with the accepted wire vocabulary.
queryValue :: ReadQuery -> Aeson.Value
queryValue (AddressQuery (Address a)) = Aeson.object ["utxos_at" .= hex a]
queryValue (AssetQuery (PolicyId p) (AssetName n)) = Aeson.object ["utxos_with_asset" .= Aeson.object ["policy_id" .= hex p, "asset_name" .= hex n]]

-- | One complete nonempty socket request.
batchLine :: NonEmpty ReadQuery -> ByteString
batchLine qs = encodeLine ["read_view" .= map queryValue (NE.toList qs)]

-- | Independent point rendering from a history event.
wirePoint :: Point -> (Integer, Text)
wirePoint (SlotNo s, BlockHash bh) = (toInteger s, hex bh)

-- | Independent reference rendering.
wireTxIn :: TxIn -> Text
wireTxIn (TxIn tid ix) = hex tid <> "#" <> Text.pack (show ix)

-- | Full expected wire contents from the pure state.
expected :: NonEmpty ReadQuery -> Point -> State -> BatchAnswer
expected qs p st = BatchAnswer (wirePoint p) (map answer (NE.toList qs))
  where
    answer (AddressQuery a) = AddressRows [(wireTxIn t, hex (unTxOut (outBytes o))) | (t, (o, _)) <- Map.toAscList st, outAddress o == a]
    answer (AssetQuery (PolicyId pol) (AssetName name)) =
        AssetRows
            [ Match (wireTxIn t) (hex (unTxOut (outBytes o))) (Text.pack (show q)) (wirePoint created) (outDatum o)
            | (t, (o, created)) <- Map.toAscList st
            , (p', n, q) <- outAssets o
            , p' == pol
            , n == name
            ]

-- | Materialized library value predicted independently of production reads.
expectedView :: NonEmpty ReadQuery -> Point -> State -> IndexedView
expectedView qs p st = IndexedView p (fmap answer qs)
  where
    answer (AddressQuery a) = AddressResult [(t, outBytes o) | (t, (o, _)) <- Map.toAscList st, outAddress o == a]
    answer (AssetQuery (PolicyId pol) (AssetName name)) =
        AssetResult
            [AssetMatch t (outBytes o) q s bh | (t, (o, (s, bh))) <- Map.toAscList st, (p', n, q) <- outAssets o, p' == pol, n == name]

-- | Reachable move, rollback and same-slot/different-hash fork histories.
script :: [Action]
script =
    [ Apply 1 (blockHash 1) [Create (tx 0x55) (produced 0xA1 7 0), Create (tx 0x44) (produced 0xA1 (2 ^ (53 :: Int) + 1) 1), Create (tx 0x33) (produced 0xB2 8 2), Create (TxIn (txInId (tx 0x33)) 2) (produced 0xB2 9 0), Create (TxIn (txInId (tx 0x33)) 10) (produced 0xB2 10 1)]
    , Apply 2 (blockHash 2) [Spend (tx 0x55), Create (tx 0x22) (produced 0xB2 7 2)]
    , Rollback 1
    , Apply 2 (blockHash 12) [Spend (tx 0x44), Create (tx 0x11) (produced 0xA1 3 2), Create (tx 0x66) (produced 0xB2 5 1)]
    , Apply 3 (blockHash 3) [Spend (tx 0x33)]
    , Rollback 2
    ]

-- | Seed only P, before a controlled advance.
seed :: IndexerHandle -> IO ()
seed h = case script of
    a : _ -> drive h a
    [] -> fail "fixture script is empty"

-- | Stable complete disclosure used by both baseline and candidate.
disclosure :: Disclosure
disclosure = Disclosure 42 (Coverage FromOrigin AllAddresses) 60 600

-- | Fixed sample with a future progress timestamp so age is always zero.
readyFixed :: ReadyStatus
readyFixed = ReadyStatus True (Just (SlotNo 3)) (Just (SlotNo 1)) (Just 2) UpstreamConnected (UTCTime (fromGregorian 2100 1 1) 0)

-- | Real production AF_UNIX server over the supplied handle.
withServer :: IndexerHandle -> (FilePath -> IO a) -> IO a
withServer h = withSocketServer (\p -> runServer p h disclosure (pure readyFixed))

-- | Initial producer state, rejecting an accidentally empty history.
firstState :: (Point, State)
firstState = case history script of
    s : _ -> s
    [] -> error "fixture history is empty"
