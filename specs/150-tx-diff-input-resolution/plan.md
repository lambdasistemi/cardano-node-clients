# Implementation Plan: Tx Diff Input Resolution

**Branch**: `150-tx-diff-input-resolution` | **Date**: 2026-05-14 | **Spec**:
`specs/150-tx-diff-input-resolution/spec.md`
**Input**: Feature specification from
`specs/150-tx-diff-input-resolution/spec.md`

## Summary

Add an opt-in input-resolution pass to `tx-diff`. Resolution is configured
via two independent CLI flag groups: one for a Blockfrost-compatible web2
endpoint (`--resolve-web2 URL [--web2-api-key-file PATH]`) and one for a local
cardano-node N2C socket (`--resolve-n2c PATH --network-magic N`). When at
least one resolver is configured, tx-diff collects every `TxIn` referenced
in either transaction's `inputs`, `referenceInputs`, and
`collateralInputs`, asks the configured resolvers for the matching `TxOut`s,
and attaches each resolved `TxOut` as a child of the existing `TxIn`
projection so the renderer descends into address/coin/datum/referenceScript
the same way it descends into body outputs. Unresolved inputs render without
the new children; tx-diff prints one stderr line per unresolved input
naming the input and the resolver(s) that failed. The default
no-flag behavior is byte-identical to current main.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.3
**Primary Dependencies**: existing `cardano-ledger-conway` and
`Cardano.Node.Client.Provider`; new `http-client` + `http-client-tls` (or
`http-conduit` if already available in CHaP) for the Blockfrost call;
existing `Cardano.Node.Client.N2C.Connection.runNodeClient` plus
`Cardano.Node.Client.N2C.Provider.mkN2CProvider` for the N2C resolver.
**Storage**: N/A.
**Testing**: Hspec via `just unit`. Web2 resolver is exercised against a
local fake HTTP server (`warp` or `http-server` thread inside the test);
N2C resolver is exercised via a fake `Provider` record, not the full mini-
protocol — the existing test pattern uses `mkN2CProvider lsq` against the
devnet, which is too heavy for the per-resolver semantics check.
**Target Platform**: Linux/macOS CLI.
**Project Type**: Haskell library + CLI executable.
**Performance Goals**: One HTTP round-trip per *distinct* `TxId` requested
via web2; one LSQ batch for all `TxIn`s requested via N2C. Linear in input
count for the merge.
**Constraints**: No new behavior without an opt-in flag. No transaction
submission. Existing tx-diff fixtures must produce byte-identical output
with no flags. Blueprint decoding for resolved datums uses the existing
decoder, no new blueprint logic.
**Scale/Scope**: Conway transactions only. Inputs only (the three input
lists). Output projections are unchanged.

## Constitution Check

- Channel-driven N2C: the N2C resolver reuses
  `Cardano.Node.Client.N2C.Connection.runNodeClient` and `mkN2CProvider`
  rather than opening a hand-rolled socket.
- Devnet E2E testing: there is no new E2E surface for the web2 path
  because that would require running a real Blockfrost. We use a local
  fake HTTP server in unit tests, which is consistent with "no mocks for
  *node* communication" — the node communication path still goes through
  the real Provider abstraction.
- Minimal dependencies: `http-client` + `http-client-tls` are widely used
  upstream and already available through the existing flake; we will
  confirm that's the case in the first implementation slice and pick the
  smallest http library Haskell.nix offers if not.
- Test utilities first-class: the resolver abstraction is exported so
  downstream consumers (and tests) can supply their own resolvers without
  touching the CLI.

## Project Structure

### Documentation

```text
specs/150-tx-diff-input-resolution/
├── spec.md
├── plan.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── cli.md
└── tasks.md
```

### Source Code

```text
lib/Cardano/Node/Client/TxDiff.hs              # core diff: attach resolved TxOut to TxIn projection
lib/Cardano/Node/Client/TxDiff/Cli.hs          # CLI parser: new flags
lib/Cardano/Node/Client/TxDiff/Resolver.hs     # NEW: Resolver type, chain, diagnostics
lib/Cardano/Node/Client/TxDiff/Resolver/Web2.hs # NEW: Blockfrost CBOR resolver
lib/Cardano/Node/Client/TxDiff/Resolver/N2C.hs  # NEW: N2C-via-Provider resolver
app/tx-diff/Main.hs                            # wire CLI to resolvers; pre-flight + run
test/Cardano/Node/Client/TxDiff/CoreSpec.hs    # diff-shape tests with synthetic resolved inputs
test/Cardano/Node/Client/TxDiff/CliSpec.hs     # new flag parsing tests
test/Cardano/Node/Client/TxDiff/ResolverSpec.hs # NEW: resolver-chain semantics
test/Cardano/Node/Client/TxDiff/Web2Spec.hs    # NEW: web2 resolver against a local fake HTTP server
cardano-node-clients.cabal                     # new modules + http-client deps
docs/executables/tx-diff.md                    # new flags + privacy/trust notes
```

**Structure Decision**: The resolver lives in a new module subtree under
`Cardano.Node.Client.TxDiff.Resolver.*` so the diff core stays oblivious to
HTTP and to the Provider record. `TxDiff.hs` only sees a small `Resolved
TxIn` map (`Map TxIn (TxOut ConwayEra)`), which is what feeds the projection.
The CLI assembles a resolver from flags and calls it before the diff is
computed.

## Design

### Resolver abstraction

```haskell
-- Cardano.Node.Client.TxDiff.Resolver
data Resolver = Resolver
    { resolverName :: Text
    , resolveInputs :: Set TxIn -> IO (Map TxIn (TxOut ConwayEra))
    }

-- Run a chain of resolvers in order. The first resolver is given all
-- inputs; later resolvers receive only the inputs the earlier ones
-- could not resolve. Returns the union and the set of still-unresolved
-- TxIns annotated with the resolver names that were tried.
resolveChain :: [Resolver] -> Set TxIn
             -> IO (Map TxIn (TxOut ConwayEra), Map TxIn [Text])
```

The chain is the only place that knows about ordering. The CLI builds the
list as `[n2cResolver] ++ [web2Resolver]` (filtered by flags). With no
flags, the chain is empty and resolution is a no-op.

### Diff core change

`conwayDiffProjection` for `ConwayTxInValue` currently returns
`DiffAtomic (txInValue txIn)`. We change it to consult a resolution map
passed via `TxDiffOptions`:

```haskell
data TxDiffOptions = TxDiffOptions
    { txDiffIncludeWitnesses :: Bool
    , txDiffDecodeData       :: Maybe TxDiffDataDecoder
    , txDiffResolvedInputs   :: Map TxIn (TxOut ConwayEra) -- NEW
    }
```

When `txDiffResolvedInputs` is empty (default), the projection stays atomic
and the output is byte-identical to today (this is the test fixture
guarantee). When a TxIn has an entry, the projection becomes an object with
the existing atomic value at `"txIn"` and the existing `ConwayTxOutValue`
projection at `"resolved"`. Children of `"resolved"` are exactly the four
fields the body-output projection already produces.

### Web2 resolver (Blockfrost CBOR)

`GET <URL>/txs/{hash}/cbor` with the `project_id` header set from
`--web2-api-key-file`. Response body is JSON `{"cbor": "<hex>"}`. We decode the
hex via the existing `decodeConwayTxHex`, then index outputs by `TxIx`. We
deduplicate by `TxId` within a single tx-diff run to avoid multiple HTTP
calls when the same prior transaction is referenced more than once. Any
HTTP error, decode failure, or out-of-range index marks each affected
`TxIn` as unresolved by `web2` for diagnostic purposes; tx-diff does not
fail.

Startup validation: an obviously malformed URL (no scheme, no host) is
rejected before the transactions are read. A missing API key when the URL
template needs one is *not* validated up-front; we discover that on the
first call and surface it via stderr.

### N2C resolver

Open an `LSQChannel`, run `runNodeClient` in a background thread, build a
`Provider` with `mkN2CProvider`, call `queryUTxOByTxIn` with the full input
set, and tear the connection down. The N2C resolver may return fewer
entries than requested — that's the "already spent" case and is expected.
Tear-down uses a bracketed `withAsync`.

Startup validation: missing socket file or invalid network magic causes the
whole tx-diff invocation to exit non-zero before reading transactions.
Inputs that the node could not resolve (returned empty entry) are reported
via stderr as unresolved by `n2c`.

### CLI surface

```text
tx-diff [render flags] [--collapse-rules FILE] [--blueprint FILE ...]
        [--resolve-n2c PATH --network-magic N]
        [--resolve-web2 URL [--web2-api-key-file PATH]]
        TX_A TX_B
```

Existing flags are unchanged. `--network-magic` is required when
`--resolve-n2c` is set; `--web2-api-key-file` is optional (some Blockfrost-
compatible self-hosted endpoints do not require one).

Exit codes:

- 0 — no diffs.
- 1 — diffs present (existing behavior).
- 2 — pre-flight resolver failure (bad socket, bad URL form, missing
  required flag combination). Existing CLI parser already returns non-zero
  on parse errors; this is the same channel.

### Diagnostics

For each unresolved `TxIn`, exactly one stderr line:

```text
tx-diff: input <txId>#<ix> not resolved by [<resolver-1>, <resolver-2>]
```

Order in the bracket matches the resolver chain order. With only one
resolver configured, the list has one element.

## Proof Strategy (per slice)

Each behavior-changing slice has a RED test that fails on `origin/main`
and is fixed in the same commit by the GREEN implementation. Solo mode:
RED + GREEN fold into one bisect-safe commit; we never push the RED-only
intermediate state.

- Slice A — diff-core takes resolved inputs and projects them as a TxOut
  subtree. RED: a `CoreSpec` test feeds a synthetic resolution map and
  expects the rendered tree to include `address`, `coin`, `datum`,
  `referenceScript` under `body.inputs.0`. GREEN: change
  `ConwayTxInValue` projection and `TxDiffOptions`.
- Slice B — resolver abstraction + chain semantics. RED: `ResolverSpec`
  tests that a single resolver, a chain of two with full coverage, and a
  chain of two with partial coverage all return correct merged maps and
  unresolved sets. GREEN: implement `Resolver` and `resolveChain`.
- Slice C — N2C resolver. RED: a fake `Provider` record returning a fixed
  map is wrapped by the N2C resolver and produces the expected map.
  GREEN: implement `Resolver.N2C.fromProvider :: Provider IO -> Resolver`
  and a small wiring helper that opens the socket from CLI flags.
- Slice D — web2 Blockfrost resolver against a local fake HTTP server.
  RED: a `Web2Spec` test stands up a local server that returns the CBOR
  for a known tx and asserts the resolver returns the expected
  `(TxIn, TxOut)`. Also covers HTTP 404 (unresolved) and bad JSON
  (unresolved). GREEN: implement `Resolver.Web2.blockfrost`.
- Slice E — CLI wiring + diagnostics + offline default. RED: `CliSpec`
  tests for the new flags' parsing; a `Main`-level test that no-flag
  fixtures produce byte-identical output to the existing golden. GREEN:
  parser changes + `Main.hs` integration. Also adds the diagnostic-line
  stderr behavior with a small assertion in `Main` integration test or a
  module-level helper test.
- Slice F — docs (`docs/executables/tx-diff.md`) describing flags,
  trust/privacy implications, and how N2C resolution sees only currently-
  unspent UTxOs.

Each slice runs `nix develop --quiet -c just ci` (the gate from
`llm/reviews/local-150-tx-diff-input-resolution/gate.sh`) before pushing.

## Gate

`llm/reviews/local-150-tx-diff-input-resolution/gate.sh` runs:

```bash
nix develop --quiet -c just ci
```

A live-boundary smoke is *not* added to the gate. Web2 resolution against
real Blockfrost requires an API key and external network; N2C resolution
requires a live node. Both are documented as operator follow-up in the new
docs section. The existing devnet E2E suite already covers `Provider`
behavior; the N2C resolver is a thin shim and adds no new node-protocol
risk.

## Risks And Open Questions

- **http-client availability in haskell.nix**: confirm `http-client` /
  `http-client-tls` build under our pin. If not, fall back to
  `http-conduit` or `req`.
- **Network magic ergonomics**: requiring `--network-magic` alongside
  `--resolve-n2c` is correct but verbose. For mainnet/preview/preprod we
  could later accept a name; out of scope for this slice.
- **Diagnostic ordering**: stderr lines are emitted in TxIn-sort order so
  output is reproducible across runs. The chain order in the bracket is
  the configured chain order, also reproducible.
- **Decoded datum size**: a resolved output may carry a very large datum
  that blows up rendered diff lines. Collapse rules already exist for that
  and apply here unchanged.

## Status

**Completed**: Worktree at `/code/cardano-node-clients-issue-150` on branch
`150-tx-diff-input-resolution`. Draft PR #151. Spec written; this plan
written.
**Current**: Awaiting plan self-review; then tasks.md.
**Blockers**: None.

## Complexity Tracking

No constitution violations. The only new external surface is HTTP, scoped
to a single resolver behind a single flag pair, and isolated behind
`Resolver.Web2`.
