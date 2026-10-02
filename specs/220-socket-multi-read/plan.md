# Implementation plan — #220 intake proposal

Pending epic-owner acceptance of this directory and its provisional wire schema.
This commit contains planning Markdown only. No feature tests/faults have run.

## Existing surfaces relied on

- `lib-utxo-indexer/Cardano/Node/Client/UTxOIndexer/Indexer.hs` exposes
  `readView :: NonEmpty ReadQuery -> IO (Either AssetQueryUnavailable IndexedView)`;
  queries/results are ordered and materialized in one transaction on both
  backends. Address-only views already refuse unavailable asset indexes.
- `lib/Cardano/Node/Client/UTxOIndexer/Server.hs` owns parsing/dispatch/encoding.
  `runServer` keeps its public signature. Existing point, holder, datum and
  refusal encodings remain authoritative; no storage/schema/API migration.
- `WireClient.hs` exercises a real AF_UNIX server to EOF; library fixtures and
  `IndexedViewSpec.hs` provide independent ledger-output/model leads, not a
  substitute for the socket proof. Existing faults stay distinct and unchanged.
- `nix/checks.nix` provides `mkFaultSpec`, applied-patch status and the shared
  fault runner. `flake.nix` builds that runner from faulted production source;
  `nix/apps.nix` already exports gate scripts. Reuse this mechanism.

These are reliance declarations from source inspection, not fresh behavioral
proof. The inherited library fault remains required by `gates.md`.

## One coherent implementation commit after intake acceptance

No source inspection demonstrates a need to split this additive socket slice.
Proposed subject: `feat: serve atomic socket read views for #220`.
The ticket owner freezes accepted schema, file fence and gates before dispatch.

1. Author executing socket specs, strict response reader and independent state
   oracle. Show missing batch behavior RED against the pre-feature server;
   compilation/setup failure is not that RED. Preserve all existing specs.
2. Append validated batch parsing; make one `readView` call; encode ordered
   results from its view. Factor only the encoding helpers needed to share
   existing member/refusal encodings without changing legacy bytes or behavior.
3. Add socket split-snapshot production fault and register its exact guard path
   in the shared runner, Nix check/app and CI build-gate/downstream job.
4. Document actual request, response, point and all refusal reasons in
   `docs/usage/utxo-indexer.md`; verify examples against socket cases.
5. Produce normal GREEN, fault RED/KILLED, legacy byte evidence, all inherited
   CI checks and exact-head local CI receipts; submit to a fresh source auditor.
   Push, PR lifecycle and acceptance belong to the ticket/epic owners.

## Proposed implementation paths and responsibilities

| Path | Intended change |
|---|---|
| `lib/.../UTxOIndexer/Server.hs` | Private request/response additions, validation and single-view dispatch. |
| `test/.../UTxOIndexer/SocketReadViewSpec.hs` | Real socket, model oracle, validation/refusal and controlled-advance guard. |
| `test/.../UTxOIndexer/SocketReadViewStabilitySpec.hs` | All four legacy endpoints and ambiguous-request byte property. |
| `test/.../UTxOIndexer/PreReadViewServer.hs` | Frozen inspected-base Server source; module rename only; runtime byte oracle. |
| `test/.../UTxOIndexer/WireClient.hs` | Add strict batch reader without weakening existing asset decoder. |
| `test/unit-main.hs`, `test/fault-check-main.hs`, `cardano-node-clients.cabal` | Compile/register new specs in unit and fault runner as applicable. |
| `nix/faults/socket-view-snapshot-binding.patch` | Production server fault only, never oracle or guard edits. |
| `nix/checks.nix`, `.github/workflows/ci.yml` | New fault gate using existing check/app export; preserve every inherited gate. |
| `docs/usage/utxo-indexer.md` | Required socket user documentation. |

Ellipses above expand to `Cardano/Node/Client`; no new public API or dependency
is proposed. Library production code stays unchanged unless a demonstrated
contract defect is returned to the parent before implementation.

## Executing atomicity and point-binding witness

Use one full Hspec guard path:
`utxo-indexer socket read view/every answer equals independent state at the reported point across a controlled advance`.
It is selected identically on normal and faulted builds and runs both in-memory
and RocksDB stores behind the production server and a real AF_UNIX connection.

Build ledger outputs, retain their serialized bytes, asset facts and datum
facts independently of production extraction. Fold applies/spends/rollback
into a pure map keyed by `(slot, blockHash)` and TxIn. Reject fixture reuse of
a TxIn with different address or output bytes. A move spends one reference and
creates another; changes cannot be invented by relocating the same TxIn.
Use at least two addresses, multiple holders, mixed queries and duplicates;
make P and Q differ in address rows, holder identities/quantities and provenance.
Also exercise rollback/fork histories with equal slots and distinct hashes.

Deterministic socket seam: pass `runServer` a handle whose `readView` wrapper
delegates unchanged to the real store, fully forces the first returned view,
then signals a writer and waits for its acknowledged apply P→Q before returning
that view. Later calls delegate normally. Record request identity, query count,
captured P, committed Q and acknowledgement; bound all waits with timeouts.
The wrapper supplies no answers and never fabricates or alters the view.
For normal dispatch all queries were already read atomically at P; the advance
occurs before response processing. For split dispatch the advance is between
the first and later query reads within the same socket request. This explicitly
tests the server seam without claiming to interrupt the library transaction.
Assert writer completion and a real point change in the selected example;
failure to establish them is setup failure, not a killed semantic fault.

Decode the wire response with an independent exact-key reader. Look up the
reported full point in the model, and compare every ordered answer's complete
contents with that state: references, bytes, quantities, datum and creation
point. Assert cardinality, duplicate correlation, multiple nonempty members
and fixture discrimination (the later queried answers differ between P and Q).
The oracle must not use `snapshotAt`, `assetUtxos`, `readView`, the server
encoder or production extraction to predict expected answers.

Fault: replace only the new server branch's single batch `readView` with an
ordered traversal of singleton `readView` calls, combine their results and
report the first view's point. The first call triggers P→Q via the same wrapper;
later answers contain Q data stamped P. The model-content assertion must fail
with an expected/actual mismatch, not merely a call-count or point-only check.
Keep this separate from `fault-view-snapshot-binding`, which faults the library.

## Other proofs and controls

- Validation covers empty/nonarray batches, unknown/two keys, wrong types,
  malformed hex, policy/name bounds, duplicates, case-insensitive input and
  an invalid later query after a valid first. A read counter confirms invalid
  input does not touch storage; counters do not prove atomicity.
- Socket refusals cover empty/restoration-only, degraded/incomplete, rebuilding
  and inconsistent joins/undecodable asset output; test mixed and address-only
  batches wherever the library refusal applies. Available no-match succeeds.
- Baseline server at the inspected base and candidate receive identical generated
  lines on a quiescent store. Compare all legacy response bytes including LF,
  disclosure and EOF. Use the same readiness/disclosure and a future progress
  timestamp so existing clamped age is deterministically zero on both servers.
  Cover every legacy success/refusal, invalid-early/valid-later precedence,
  valid and invalid `read_view` keys alongside legacy keys and malformed input.
  Require equality for every line the baseline accepts and malformed lines
  without `read_view`; only baseline-rejected lines carrying `read_view` may
  acquire the new response/error. Never exempt baseline invalid-asset answers.
  Flip each byte in representative legacy responses to falsify the comparator.
- Retain every inherited unit/E2E/disclosure/stability spec and CI job. Review
  docs against executing wire cases; do not add a bespoke runtime gate script.

## Failure modes

The existing `runServer` forks each connection; `handleConn` wraps storage reads
and response writes in `finally close conn`. A storage-read exception escapes
that handler and closes its connection: the client receives EOF without a
response line. Future implementation must verify that this observable behavior
is preserved, including for batch reads; do not introduce an error response or
change resource acquisition or threading to address this failure mode.

## Evidence required before behavior acceptance

Receipts bind base/candidate/tree, exact command, duration, exit, log hash/path,
cache state and invocation count. Require the selected example actually runs
once with zero pending, normal GREEN, witnessed P→Q, discriminating contents,
fault patch applied/compiled, the same example failing on contents, and outer
`FAULT-CHECK ... outcome=KILLED` exit 0. SURVIVED, skips, exceptions, timeouts,
patch/build/setup failures do not count. No such evidence is claimed here.
