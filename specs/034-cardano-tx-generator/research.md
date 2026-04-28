# Phase 0 Research — cardano-tx-generator

## Sources surveyed

Files and modules verified on `main` (commit `1523e58`) by an Explore
sub-agent on 2026-04-28. All citations are `module:line` in this
repo's worktree at `/code/cardano-node-clients-issue-84`.

## API summary (verbatim from sub-agent dump)

### In-tree address-to-UTxO indexer library (PR #79, merged)

- `Cardano.Node.Client.UTxOIndexer.Indexer.withInMemoryIndexer ::
  (IndexerHandle -> IO a) -> IO a`
- `Cardano.Node.Client.UTxOIndexer.Indexer.withRocksDBIndexer ::
  FilePath -> (IndexerHandle -> IO a) -> IO a`
- `IndexerHandle` (Indexer.hs:175–233) exposes `applyAtSlot`,
  `rollbackTo`, `pruneRollbacks`, `snapshotAt`, `awaitTxIn`,
  `getResumePoints`. All `IO`.
- The indexer **does NOT own** an N2C connection. It accepts
  `Fetched` records from outside via the `Intersector` seam from the
  `chain-follower` package. The merged daemon's `Daemon.hs:102–131`
  glues `mkChainSyncN2C` to the indexer's `applyAtSlot`.
- Persistence: rollback inverses live in column 0; cold boot starts
  from `Origin`, warm boot resumes from the newest retained
  `(SlotNo, BlockHash)`.
- Readiness: `ReadyStatus` `TVar` updated on every `rollForward`.

### TxBuild DSL

- `Cardano.Node.Client.TxBuild.build` returns `IO (Either
  (BuildError e) ConwayTx)`; takes `PParams ConwayEra`,
  `InterpretIO q`, an exunits evaluator, inputs, ref-inputs, change
  address, and a `TxBuild q e a` program.
- `Balance.balanceTx` returns `IO (Either BalanceError
  BalanceResult)`; `BalanceResult { balancedTx, changeIndex }`
  (Balance.hs:106–109). `changeIndex` is exactly what we need to
  compute the change `TxIn` to `awaitTxIn` on.
- Pub-key spends: `spend :: TxIn -> TxBuild q e Word32`. Plain pay:
  `payTo :: Addr -> MaryValue -> TxBuild q e Word32`. Both
  sufficient for the K-output fan-out + change shape.
- Signing: `addKeyWitness :: SignKeyDSIGN Ed25519DSIGN -> ConwayTx
  -> ConwayTx` (E2E/Setup.hs:174–186). Existing pattern in
  `e2e-test/.../E2E/TxBuildSpec.hs` covers self-transfer + balance
  + sign + submit verbatim.

### N2C plumbing

- `Cardano.Node.Client.N2C.Connection.runNodeClient ::
  NetworkMagic -> FilePath -> LSQChannel -> LTxSChannel -> IO
  (Either SomeException ())` opens **one** Unix socket and
  multiplexes **two** mini-protocols on the same mux session:
  LTxS (num 6) and LSQ (num 7). See the `[MiniProtocol]` list at
  `Connection.hs:163–202` — both entries belong to the same
  `OuroborosApplication`.
- `Cardano.Node.Client.N2C.ChainSync.runChainSyncN2C ::
  EpochSlots -> NetworkMagic -> FilePath ->
  N2CChainSyncApplication -> IO (Either SomeException ())` opens
  its OWN Unix socket and serves ChainSync (num 5) alone.
- `Cardano.Node.Client.N2C.LocalTxSubmission.submitTxN2C ::
  LTxSChannel -> GenTx Block -> IO (Either (ApplyTxErr Block) ())`.
- `Cardano.Node.Client.N2C.Provider.mkN2CProvider :: LSQChannel ->
  Provider IO` (one-shot PParams query at startup is enough).
- The merged indexer's `Daemon.hs:120` does `concurrently_
  chainAction serverAction` — `serverAction` is the indexer's
  **own NDJSON Unix socket server** (read API to its clients),
  NOT a second N2C connection. The indexer daemon opens exactly
  **one** N2C connection (chain-sync only).
- **No combined entry point** that puts ChainSync + LSQ + LTxS on
  one mux session yet. The cardano-node N2C handshake
  (`NodeToClientV_20`) supports all three together; what's missing
  is a Haskell-side helper.

### HD-style key derivation

- In tree: only single-key derivation via `mkSignKey :: ByteString
  -> SignKeyDSIGN Ed25519DSIGN` (E2E/Setup.hs:150–172). Accepts
  exactly 32 bytes via `mkSeedFromBytes`.
- BIP32 / CIP-1852 are **not** in tree.

### E2E harness

- `Cardano.Node.Client.E2E.Setup.withDevnet :: (LSQChannel ->
  LTxSChannel -> IO a) -> IO a` brings up `cardano-node`, opens
  channels, runs the action.
- `E2E.ChainPopulator` (issue #28's predecessor) is the closest
  structural precedent for an external-driver test against a real
  devnet. Reuse its CPS shape for the e2e tests of this feature.

## Decisions

### D1 — Indexer is embedded via the `Intersector` seam

The daemon owns an N2C ChainSync client (`runChainSyncN2C`). On
each `Fetched` block it calls `IndexerHandle.applyAtSlot`; on
rollback it calls `IndexerHandle.rollbackTo`. This is the same
glue pattern `Daemon.hs:102–131` already uses, lifted out of the
indexer-only daemon and into the tx-generator process.

**Rationale**: minimum diff to upstream, no library refactor, no
cross-process IPC, the indexer remains a library consumer.

**Alternatives considered**:
- Embed via the published HTTP/NDJSON `Server.hs` over a Unix
  socket within the same process. Rejected: pointless serialisation
  overhead for an in-process consumer, and adds a parallel control
  surface. The library seam is the right one.

### D2 — One physical N2C connection, three mini-protocols (via [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95))

The spec's FR-008 ("one N2C connection") is met literally: a
single `connectTo` against the relay's Unix socket negotiates one
mux session that carries ChainSync (num 5), LSQ (num 7), and
LTxS (num 6) as three `MiniProtocol` entries on one
`OuroborosApplication`. The cardano-node N2C handshake
(`NodeToClientV_20`) already supports this; the gap is
Haskell-side: `runNodeClient` covers LTxS + LSQ today, and
`runChainSyncN2C` covers ChainSync on its own socket. There's no
combined entry point yet.

**Decision**: file [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95)
to add `runNodeClientFull` next to `runNodeClient`, extending
`mkN2CApp`'s `[MiniProtocol]` list with a third entry for ChainSync
wired to the chain-sync client peer that `mkChainSyncN2C` already
produces. ~30–50 LoC. The tx-generator depends on [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95);
both ship in the same PR (this branch).

**Rationale**: small, surgical, exactly what the existing code
shape already gestures at. Avoids two physical sockets per
process for what is logically one upstream interface.

**Alternatives considered**:
- Open two physical connections (one for ChainSync via
  `runChainSyncN2C`, one for LSQ + LTxS via `runNodeClient`).
  Rejected: violates FR-008 literally and is wasteful — the
  cardano-node N2C model is one mux per consumer.
- Migrate the indexer's `Daemon.hs` to the new helper too.
  Rejected for this PR — separate follow-up; not blocking.

### D3 — Flat deterministic key derivation (not BIP32)

`signKey_i = mkSignKey (blake2b_256 (masterSeed || encodeWord64 i))`,
where `i` is the HD index. The "address population" is the set
`{ enterpriseAddr (keyHash signKey_i) | i ∈ [0, nextHDIndex) }`.

**Rationale**: stays in the in-tree single-key Ed25519 surface
(no new dep on `cardano-addresses` or BIP32), trivially
deterministic, supports indefinite population growth.

**Spec reconciliation**: the spec uses "HD-derived" loosely. The
plan-side amendment to FR-003 / FR-004 will replace "HD-derived"
with "deterministically derived by index" and keep the rest of
the wording. Functionally unchanged.

**Alternatives considered**:
- Add `cardano-addresses` for CIP-1852-compliant chains. Rejected
  for v1: extra dependency, no caller asked for BIP32 conformance.

### D4 — Protocol parameters queried once at startup

`mkN2CProvider` over LSQ at startup yields `PParams ConwayEra`;
cached for the process lifetime. No re-query during the run.

**Rationale**: devnet protocol params don't change inside a run.
Re-querying introduces a non-determinism axis (LSQ batching) we'd
have to argue about for FR-002.

**Alternatives considered**:
- Re-query each tick. Rejected: complicates determinism contract
  and adds LSQ traffic for no test signal.

### D5 — Persistence: two files in `--state-dir`

- `master.seed` — 32 bytes, read-only after first write, set by
  `--master-seed-file` or generated on bootstrap.
- `next-hd-index` — text file, single decimal integer, atomically
  rewritten on each successful trigger (`tempfile + fsync + rename`).

**Rationale**: tiny, atomic-renameable, trivially restartable.
Persistence of the indexer's RocksDB or in-memory state is the
indexer library's concern, not ours.

**Alternatives considered**:
- Single JSON state file. Rejected: marginal benefit, more parsing
  surface to test.
- Embed in the indexer's RocksDB. Rejected: couples our state to
  the indexer's storage choice.

### D6 — Indexer backend: in-memory in v1

Use `withInMemoryIndexer`. RocksDB is a CLI flag (`--db-path`)
defaulting off, surfaced for future long-running tests.

**Rationale**: devnet cold start is seconds; the indexer's own
project explicitly accepts this trade-off. Less moving parts
during the first integration with Antithesis.

**Alternatives considered**:
- RocksDB by default. Rejected: more failure modes (warm-boot
  divergence per Daemon.hs:201) for no v1 benefit.

### D7 — Control wire: NDJSON over Unix `SOCK_STREAM`

Same idiom as `UTxOIndexer.Server`. One request per connection
(JSON object on a single line, `\n`-terminated), one response,
EOF-and-close. Request keys: `transact`, `refill`, `snapshot`,
`ready`. Wire schemas in `contracts/control-wire.md`.

**Rationale**: identical to the indexer's existing convention;
operators learn one wire, not two; trivial to script from Bash.

**Alternatives considered**:
- gRPC, HTTP+JSON, MessagePack. All rejected: more dependencies,
  no benefit at this scale, no symmetry with the indexer wire.

### D8 — Era pinned to Conway; network magic configurable

`PParams ConwayEra` everywhere; `--network-magic NAT` from CLI.

### D9 — Build shape per `transact`

```
spend src                 -- 1 input
payTo dst_1 v_1           -- K outputs at sampled values
payTo dst_2 v_2
...
payTo dst_K v_K
-- change is implicit: balanceTx puts the residue at change addr (= source addr)
```

The change `TxIn` is `(txId, BalanceResult.changeIndex)`; that's
the `TxIn` we feed to `awaitTxIn`.

### D10 — RNG: `mkStdGen seed` per request

Source pick, destination picks (uniform from `[0, nextHDIndex)`),
fresh-vs-existing coin flips (Bernoulli `prob_fresh`), and per-output
value samples (uniform on `[minUTxO, available/K]`) all read from a
single `StdGen` initialised from the request's seed. No `IO`-side
RNG anywhere on the tx path.

## Open questions resolved during research

- **Q**: Does the indexer expose a "with"-pattern that takes a chain
  source from the caller? **A**: Yes, `withInMemoryIndexer` /
  `withRocksDBIndexer` give an `IndexerHandle`; the caller drives
  `applyAtSlot` / `rollbackTo` from any source they like.
- **Q**: Can multiple N2C clients hit the same relay socket
  concurrently? **A**: Yes — that's already what `Daemon.hs` does
  via `concurrently_`. No upstream change needed.
- **Q**: Does TxBuild's `BalanceResult` give us the change `TxIn`?
  **A**: Yes — `changeIndex` is the index into the balanced tx's
  outputs of the change UTxO. Combine with `txid balancedTx` to
  form the `TxIn` for `awaitTxIn`.
- **Q**: Is there an in-tree HD scheme? **A**: No (only single-key
  Ed25519 from a seed). D3 closes this.

## Spec amendments needed (recorded for plan + tasks)

- **FR-003 / FR-004** wording: replace "HD-derived" with
  "deterministically derived by index from a master seed".
  (Functionally unchanged; just stops misleadingly implying
  CIP-1852/BIP32 conformance.)

FR-008 stays as written ("exactly one N2C connection") — the
upstream addition tracked in [#95](https://github.com/lambdasistemi/cardano-node-clients/issues/95)
makes it literally true.
