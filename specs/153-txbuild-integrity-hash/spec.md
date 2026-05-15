# Feature Specification: TxBuild self-validates against ledger Phase-1

**Feature Branch**: `153-txbuild-integrity-hash`
**Created**: 2026-05-15
**Status**: Draft
**Input**: GitHub issue [lambdasistemi/cardano-node-clients#153](https://github.com/lambdasistemi/cardano-node-clients/issues/153)

## Background

TxBuild today can emit a Conway transaction body that fails ledger
Phase-1 validation. The concrete bug surfaced as a
`script_integrity_hash` (CBOR key `0b`) mismatch — reproduced on
mainnet via `amaru-treasury-tx swap-cancel`
(tx `84b2bb78f7f5dd2beb2830e8e6e88fd853a8f70ea73b161f0a0327de8c70146f`):

```
script integrity hash mismatch
  expected (ledger):  41a7cd5798b8b6f081bfaee0f5f88dc02eea894b7ed888b2a8658b3784dcdcf9
  provided (body):    03e9d7edc4e9b65b14a6076b19c7f13810292687b0c51b14c038ee4849f81941
```

The deeper problem is that the only way the bug was discovered was
*downstream* — when a consumer submitted the tx and the ledger
rejected it. The cross-referenced companion ticket on
`amaru-treasury-tx` proposes a post-build validation gate in the
consumer. That is the wrong place: every consumer would have to
re-implement the same gate. TxBuild itself must guarantee that its
output is ledger-valid.

This spec re-scopes the work: fix the `script_integrity_hash`
divergence *and* make TxBuild responsible for validating every body
it produces against the ledger's Phase-1 rules before returning it.
The integrity-hash bug becomes one instance of a class TxBuild now
self-detects.

## User Scenarios & Testing *(mandatory)*

### User Story 1 — TxBuild refuses to return a Phase-1-invalid body (Priority: P1)

A caller asks TxBuild to assemble a Conway transaction. TxBuild
computes the body, then runs the ledger's Phase-1 validation on
that body against the same `PParams` it used during assembly. If
Phase-1 rejects the body, TxBuild fails with an error that names
the Phase-1 failure (e.g. `script integrity hash mismatch`,
`fee too small`, `missing collateral`); it never returns an
invalid body to the caller.

**Why this priority**: this is the contract change that makes the
bug class impossible to surface downstream again. Without it,
fixing only the integrity-hash divergence leaves the next
ledger-side change (new era, new cost-model layout, new redeemer
form) one bug away from another silent regression.

**Independent Test**: build any Conway tx through TxBuild against a
`PParams` snapshot, capture the result. If the body is valid, the
call returns it; if forced to be invalid (e.g. by injecting a
deliberate `PParams` mismatch in a test harness), the call returns
an error naming the Phase-1 failure. No consumer-side validation
gate exists.

**Acceptance Scenarios**:

1. **Given** a TxBuild plan that, with the current code, produces a
   body the ledger would accept, **When** TxBuild assembles and
   self-validates, **Then** the call returns the body and the
   self-validation step records `applyTx … = Right _`.
2. **Given** a TxBuild plan that, with the *pre-fix* code, produced
   a body with a wrong `script_integrity_hash`, **When** TxBuild
   assembles and self-validates against the same `PParams` it
   used for assembly, **Then** before the fix the call returns an
   error naming `script integrity hash mismatch`; after the fix
   the call returns the body and self-validation passes.
3. **Given** any Conway PlutusV3 plan equivalent to the mainnet
   `swap-cancel` reproduction (Sundae V3 order, redeemer
   `Constr 1 []`, inline datum, no witness-set datums, collateral
   return), **When** TxBuild rebuilds the body offline against a
   captured mainnet `PParams` snapshot, **Then** the
   `script_integrity_hash` field equals
   `41a7cd5798b8b6f081bfaee0f5f88dc02eea894b7ed888b2a8658b3784dcdcf9`
   *and* TxBuild's self-validation returns `Right _`.

---

### User Story 2 — Consumers no longer carry a duplicate Phase-1 gate (Priority: P1)

The cross-referenced companion ticket on `amaru-treasury-tx`
(post-build Phase-1 validation gate in the consumer) is closed.
Consumers trust TxBuild's contract: a returned body is
ledger-valid against the `PParams` TxBuild was given. Nobody
duplicates the gate.

**Why this priority**: the consumer-side gate proposal is the
symptom of TxBuild's broken contract. Closing it is how we verify
the contract is now strong enough to be relied on.

**Independent Test**: search consumer codebases (starting with
`amaru-treasury-tx`) for any post-TxBuild `applyTx` /
`evaluateTxBody` style guard; expect zero. The companion ticket on
`amaru-treasury-tx` is closed with a link back to this work.

**Acceptance Scenarios**:

1. **Given** the fix has landed and TxBuild's contract is in
   force, **When** the `amaru-treasury-tx` companion ticket is
   reviewed, **Then** it is closed as superseded with a reference
   to this feature.
2. **Given** any consumer of TxBuild, **When** they call the
   builder, **Then** they need not re-validate the result before
   signing/submission to detect Phase-1 issues.

---

### Edge Cases

- **No Plutus inputs**: tx has no redeemers and no
  `script_integrity_hash` field (`SNothing`). Self-validation
  must accept this body.
- **Mixed Plutus versions**: a tx with both PlutusV2 and PlutusV3
  inputs includes only V2 and V3 cost-model language views in the
  integrity hash; self-validation enforces this.
- **PParams sourcing**: TxBuild has exactly one `PParams` instance
  in scope per build call; the same value feeds fee computation,
  exec-units estimation, `script_integrity_hash` computation, and
  self-validation. Two different `PParams` instances in a single
  build is a programming error and SHOULD be impossible by
  construction (not just by convention).
- **Inline datum, empty witness-set datums**: the witness-set
  datums map is empty; the integrity hash and self-validation
  must reflect that.
- **Stake / cert-only Conway tx**: no scripts, no redeemers. The
  body still goes through self-validation; the validation must
  not falsely require Plutus witnesses.
- **Phase-1 failure that is not `script_integrity_hash`**:
  e.g. insufficient fee, missing collateral, expired validity.
  Self-validation surfaces the failure with the ledger's own
  message; TxBuild returns an error, not a body.
- **Self-validation cost**: the call adds one ledger
  `applyTx`-style evaluation per build. Acceptable as the cost
  of a strong contract; not opt-out.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: TxBuild MUST compute `script_integrity_hash` over
  the redeemers as they appear in the transaction's Conway
  witness set (map form, witness-set key `5`), using only the
  cost-model language views for Plutus versions actually
  referenced by a redeemer in the transaction.
- **FR-002**: TxBuild MUST source the `PParams` value used for
  fee estimation, exec-units estimation, integrity-hash
  computation, and self-validation from a single `PParams`
  instance passed into the build call; the design MUST make a
  multi-instance bug structurally impossible (single argument
  threaded through, not re-fetched midway).
- **FR-003**: Before returning a transaction body, TxBuild MUST
  run the ledger's Phase-1 validation (`applyTx` or the
  equivalent functional path from `cardano-ledger-api`) on that
  body against the same `PParams` instance from FR-002 and the
  UTxO it already has in scope.
- **FR-004**: If Phase-1 validation rejects the body, TxBuild
  MUST return an error that surfaces the ledger's failure
  reason (the original `ApplyTxError` value or a faithful
  rendering thereof). TxBuild MUST NOT return the body in this
  case.
- **FR-005**: TxBuild MUST omit the `script_integrity_hash`
  field (`SNothing`) from a body that carries no redeemers and
  no datums, and self-validation MUST accept such a body.
- **FR-006**: The mainnet `swap-cancel` reproduction from issue
  #153, replayed offline against a captured `PParams` snapshot,
  MUST produce `script_integrity_hash` =
  `41a7cd5798b8b6f081bfaee0f5f88dc02eea894b7ed888b2a8658b3784dcdcf9`
  and self-validation MUST return `Right _`. This is enforced
  by a test in the project's test suite.
- **FR-007**: At least one negative test MUST exercise FR-004:
  given a deliberately invalid plan (e.g. fee artificially
  zeroed, or a forced pparams mismatch), TxBuild returns an
  error naming the Phase-1 failure and does not return a body.
- **FR-008**: The companion `amaru-treasury-tx` ticket
  (post-build Phase-1 validation gate in the consumer) is
  closed as superseded by this work. No consumer is expected to
  carry a duplicate Phase-1 gate.
- **FR-009**: The fix MUST NOT regress any existing passing
  TxBuild test in `just ci`.

### Key Entities

- **Script integrity hash**: a 32-byte BLAKE2b-256 hash committed
  to in the tx body (CBOR key `0b`) and recomputed by the ledger
  from the witnesses + cost-model language views. Mismatch is a
  Phase-1 validation failure.
- **Language view**: the cost-model entry for a single Plutus
  version, in the ledger-canonical serialization form for that
  version.
- **Redeemers (Conway witness set)**: redeemers indexed by
  `(tag, index)`, serialized as a map in Conway; the integrity
  hash uses the same serialization the witness set carries.
- **PParams instance**: the protocol-parameter value threaded
  through a single TxBuild call; single source of truth for fees,
  exec units, integrity hash, and self-validation.
- **Phase-1 validation**: the ledger's structural / static
  acceptance check, exposed via `cardano-ledger-api`'s
  `applyTx` (or equivalent); does NOT run Plutus scripts —
  Phase-2 does. The script-integrity check happens here.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 100 % of TxBuild calls that today produce a
  Phase-1-valid body continue to return that body; no false
  rejection.
- **SC-002**: 100 % of TxBuild calls that today produce a
  Phase-1-invalid body now return an error naming the ledger
  failure. The previously-shipped mainnet `swap-cancel`
  reproduction is among these and is rejected with
  `script integrity hash mismatch` against pre-fix code, and
  accepted against post-fix code.
- **SC-003**: A grep across the consumer set (starting with
  `amaru-treasury-tx`) finds zero post-TxBuild Phase-1
  validation gates; the companion ticket is closed as
  superseded.
- **SC-004**: `just ci` passes green on the branch.
- **SC-005**: A future ledger / cost-model / era change that
  breaks the equivalence is caught by TxBuild's self-validation
  in `just ci` (or in the first consumer test run), not by a
  Phase-1 rejection in production.

## Assumptions

- TxBuild has, at body-return time, access to enough state to run
  Phase-1 validation: the `PParams` instance, the slot, and the
  UTxO it already used to construct inputs/collateral. No new
  external query is required. If this turns out to be false, the
  spec will be updated and user approval requested before
  extending the API surface.
- "Ledger Phase-1 validation" in this spec means the ledger
  function exposed via `cardano-ledger-api` that performs the
  same static checks the node runs before Plutus script
  execution. Phase-2 (Plutus script execution) is out of scope —
  this work does not promise script-logic validation, only that
  bodies are well-formed and self-consistent with witnesses and
  PParams.
- The mainnet `PParams` snapshot used in the FR-006 reproduction
  is taken at a slot consistent with the failing tx's slot, so
  the cost-models in scope match those the ledger used at
  rejection time.
- The work is confined to `lib-tx-build/Cardano/Node/Client/`
  (notably `TxBuild.hs` and `Scripts.hs`) and its tests. If the
  fix forces a TxBuild public-API change, the spec is updated
  and user approval requested before the API moves.
- Closing the `amaru-treasury-tx` companion ticket is part of
  the deliverable (see FR-008 / SC-003) but happens after the
  TxBuild fix lands — the consumer ticket is closed *as
  superseded by this PR*, with a backlink.
