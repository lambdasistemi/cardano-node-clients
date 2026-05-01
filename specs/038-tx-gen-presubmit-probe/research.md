# Research: Pre-submit chain-tip UTxO probe

**Branch**: `038-tx-gen-presubmit-probe`
**Date**: 2026-05-01

This research covers the seams in `cardano-node-clients` that the probe wires
into. All file paths are repo-relative; line numbers are at HEAD of branch.

## Decisions

### D1. Probe lives behind a new `Provider` method

**Decision**: Extend `Provider IO` (`lib/Cardano/Node/Client/Provider.hs`) with
one new method `queryUTxOByTxIn :: Set TxIn -> m (Map TxIn (TxOut ConwayEra))`.
The N2C provider already imports `GetUTxOByTxIn` (`N2C/Provider.hs:66`) so the
backing query is a one-liner.

**Rationale**: Keeps the indirection consistent with the rest of the daemon —
the daemon never speaks ouroboros-network directly, only through `Provider`.
A standalone helper that reaches around the Provider would break the test
seam (unit tests stub Provider, not the wire).

**Alternatives considered**:
- Add a free function over `LSQChannel` that the daemon calls directly. Rejected:
  breaks test stubbing pattern.
- Add `verifyInputsUnspent :: Provider IO -> Set TxIn -> IO Bool` as a derived
  helper layered on `queryUTxOByTxIn`. Adopted as a thin wrapper; the boolean
  result is what the daemon needs, but the underlying `Map TxIn ...` is the
  reusable primitive and worth exposing.

### D2. Probe sits after freshness gate, before submit

**Decision**: In both `buildSignSubmit` (refill, `Daemon.hs:603`) and
`transactWithSource` (transact, `Daemon.hs:845`), after `addKeyWitness` and
before `submitTx submitter signed`, call `verifyInputsUnspent provider
(Set.fromList (txInputs signed))`. On `False`, return
`RefillFail IndexNotReady` / `TransactFail IndexNotReady` exactly as the
freshness gate already does.

**Rationale**: Spec FR-007 mandates composition with the freshness gate.
Freshness gate already runs at the very top of each arm
(`Daemon.hs:431–432`) — the probe runs *inside* the gated body so it is
unreachable when freshness is false. The probe inputs are the inputs of the
*about-to-be-submitted* tx, not the indexer's view, so it has to run after
tx construction.

### D3. ConnectionLost from the probe maps to IndexNotReady

**Decision**: The existing `E.handle ConnectionLost` wrapper around each arm
(`Daemon.hs:438–444`, `465–471`) covers the probe automatically — `queryLSQ`
inside `queryUTxOByTxIn` raises the same `ConnectionLost` that submit does.

**Rationale**: Matches spec FR-006. No new exception handling code needed.
A reconnect-storm during the probe lands in the same retry-on-next-tick path
as a reconnect-storm during submit.

### D4. HD-index advance gated on submit success, not probe

**Decision**: No change — index increment already happens only after
successful submit + confirmation (`Daemon.hs:625–627` for refill, `893–897`
for transact). When the probe rejects, the arm short-circuits before the
increment site, exactly like the freshness gate does today.

**Rationale**: Spec FR-003 satisfied by reusing existing structure.

### D5. E2E test uses `withRestartableCardanoNode`

**Decision**: New file `e2e-test/Cardano/Node/Client/E2E/TxGeneratorSubmitIdempotenceSpec.hs`,
modeled on `TxGeneratorRestartSpec` (`e2e-test/Cardano/Node/Client/E2E/TxGeneratorRestartSpec.hs:1–80`).
Use `Devnet.withRestartableCardanoNode` (`Devnet.hs:96–99`) to kill and respawn the
relay between two refill drives.

**Rationale**: The harness already exists for the post-PR-#105 reconnect spec
suite (`TxGeneratorIndexFreshSpec` per cabal line 311). One more file in the
same shape, no new infrastructure.

**Open question (track in plan, resolve in implement)**: How do we *force* a
ConnectionLost mid-write whose tx actually lands? Option A: stop the relay's
TCP listener but let its mempool drain into a block first, then restart.
Option B: add a deterministic LSQChannel wrapper that swallows MsgAcceptTx.
Option B is more reliable; Option A is closer to the production path. Decide
in implement after measuring how flaky Option A is.

### D6. Unit test for `verifyInputsUnspent` against a stubbed Provider

**Decision**: Add to existing `test/Cardano/Node/Client/TxGenerator/SelectionSpec.hs`
(or sibling `SubmitSpec.hs` if helper moves to `Submit.hs`). Stub `Provider`
with a deterministic `queryUTxOByTxIn` returning a controlled `Map`. Two
cases: all inputs present → True; one missing → False.

**Rationale**: SelectionSpec already runs against pure Provider stubs
(cabal line 255). Same pattern.

## Codebase seams (file:line)

| Seam                                | File                                   | Lines              |
| ----------------------------------- | -------------------------------------- | ------------------ |
| Refill submit                       | `lib/.../Daemon.hs`                    | 603–606            |
| Transact submit                     | `lib/.../Daemon.hs`                    | 845–858            |
| Freshness gate (refill)             | `lib/.../Daemon.hs`                    | 431–444            |
| Freshness gate (transact)           | `lib/.../Daemon.hs`                    | 460–471            |
| `ConnectionLost` handler            | `lib/.../Daemon.hs`                    | 438–444, 465–471   |
| HD-index increment (refill)         | `lib/.../Daemon.hs`                    | 625–627            |
| HD-index increment (transact)       | `lib/.../Daemon.hs`                    | 893–897            |
| `Provider` record                   | `lib/.../Provider.hs`                  | 51–75              |
| N2C `GetUTxOByTxIn` import          | `lib/.../N2C/Provider.hs`              | 66                 |
| `FailureReason` (`IndexNotReady`)   | `lib/.../TxGenerator/Types.hs`         | 128–135            |
| `Selection` module                  | `lib/.../TxGenerator/Selection.hs`     | 21–75              |
| `ConnectionLost` exception          | `lib/.../N2C/Types.hs`                 | 96–99              |
| Devnet helper                       | `e2e-test/.../E2E/Devnet.hs`           | 81–99              |
| Restart E2E spec (template)         | `e2e-test/.../TxGeneratorRestartSpec.hs` | 1–80             |

## Build / CI

- Quality gate: `nix develop --quiet -c just ci` (`justfile:17–22`):
  `just build && just e2e && cabal-fmt -c cardano-node-clients.cabal &&
  fourmolu -m check && hlint`
- Pinned tools: `nix develop` shell only — no host installs.
- `cardano-node-clients.cabal` exposes `TxGenerator.Daemon` (line 71),
  `TxGenerator.Selection` (line 75), `Provider` (line 66). Test suite
  `e2e-tests` at line 295.

## Out of scope (named here so plan stays tight)

- In-flight tx-id tracking across reconnects (Assumption 3 in spec).
- Mempool-content awareness (Assumption 1 in spec).
- Composer-side assertion framing (Assumption 4 in spec — tracked in
  https://github.com/cardano-foundation/cardano-node-antithesis/issues/107).
