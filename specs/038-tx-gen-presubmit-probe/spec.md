# Feature Specification: Pre-submit chain-tip UTxO probe in tx-generator

**Feature Branch**: `038-tx-gen-presubmit-probe`
**Created**: 2026-05-01
**Status**: Draft
**Input**: User description: "Pre-submit chain-tip UTxO probe in tx-generator daemon to prevent duplicate-submit-after-reconnect rejections (issue #111)"
**Tracks issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/111
**Builds on (already merged)**: https://github.com/lambdasistemi/cardano-node-clients/pull/105 (N2C reconnect supervisor), https://github.com/lambdasistemi/cardano-node-clients/pull/110 (indexer freshness gate, spec 037)
**Downstream consumer**: https://github.com/cardano-foundation/cardano-node-antithesis/pull/98
**Antithesis report (regression evidence)**: https://cardano.antithesis.com/report/tilehuSggX4cnuy5qyXfwpqI/2ZUJSYUipLqm3Dlbo9R3rjrS7i7dYJ_mc8FwikFqYLg.html

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Refill arm never re-submits the faucet input of a tx that already landed (Priority: P1)

A `cardano-tx-generator` daemon is supervising its N2C bearer via the auto-reconnect loop (spec 035) and the indexer freshness gate (spec 037). The composer ticks the refill arm; the daemon queries the indexer, builds Tx1 against faucet input X, and submits Tx1. The wire write succeeds and the relay accepts Tx1 into its mempool. The bearer dies before `MsgAcceptTx` round-trips back. The daemon's submit primitive raises `ConnectionLost`, the arm returns *indexer-not-ready*, the supervisor reconnects, and the freshness gate eventually re-opens.

The composer ticks the refill arm again. The daemon's local indexer view, depending on rollback dynamics, may still report X as unspent. Without further protection, the daemon would build Tx2 spending X again — but Tx1 has already been included on chain, so X is spent. The relay rejects Tx2 with `ConwayMempoolFailure "All inputs are spent. Transaction has probably already been included"`, tripping the `tx_generator_refill_submit_rejected` Always-assertion.

The daemon must, immediately before invoking the submit primitive, verify against the relay's *current* chain tip that the tx's input(s) are still unspent. If not, the arm MUST short-circuit with the same *indexer-not-ready* response used elsewhere, and MUST NOT call submit. The composer retries on the next tick.

**Why this priority**: This is the dominant residual failure mode after PR #110 closed the stale-UTxO window. The relay's rejection is correctness-preserving — a duplicate-submit cannot land twice — but the assertion is framed "should never happen", so eliminating these rejections is the bar to clear before the run goes green.

**Independent Test**: Boot a devnet via `withRestartableCardanoNode`. Drive a refill, capture the tx, restart the relay so the daemon's submit raises `ConnectionLost` mid-write but Tx1 has actually landed in the new chain. Drive a second refill that would otherwise re-submit the same faucet input. Assert that the submit primitive is not invoked, that no `ApplyTxErr` carrying `"already been included"` is raised, and that the daemon process stays alive.

**Acceptance Scenarios**:

1. **Given** the daemon has just submitted Tx1 spending input X and lost the bearer before `MsgAcceptTx` arrived, **And** Tx1 actually landed on the relay's new chain head, **When** the composer ticks the refill arm and the daemon re-builds Tx2 spending X, **Then** the pre-submit probe reports X as missing from the current tip's UTxO set, **and** the arm returns *indexer-not-ready* without calling submit.
2. **Given** the indexer's local view and the relay's chain tip agree that X is unspent, **When** the composer ticks the refill arm, **Then** the probe succeeds, **and** submit proceeds with semantics identical to before this feature.
3. **Given** the probe fails because the LSQ channel itself is unavailable (e.g. mid-reconnect), **When** the arm runs, **Then** it returns *indexer-not-ready* and does not call submit.

---

### User Story 2 - Transact arm never re-submits the source inputs of a tx that already landed (Priority: P1)

Same race as US1, applied to the *transact* arm: the daemon picks K source inputs from the indexer, builds a fan-out tx, submits it; the bearer dies before `MsgAcceptTx`; later, the indexer (still or once again) reports those K inputs as unspent and the daemon re-builds a tx against the same inputs. The relay rejects with the same `"All inputs are spent. Transaction has probably already been included"` reason, tripping `tx_generator_transact_submit_rejected`.

The pre-submit probe MUST cover the K source inputs of the transact tx in the same way it covers the single faucet input of the refill tx. On any input missing from the current tip, the arm short-circuits.

**Why this priority**: The same Antithesis run reports both `tx_generator_refill_submit_rejected` and `tx_generator_transact_submit_rejected`. The pairing is intentional — the fix is the same probe wired into a second site, not a separate mechanism.

**Independent Test**: Same devnet harness as US1, but exercise the transact arm. After a `ConnectionLost`-triggered indeterminate submit whose tx actually landed, drive a second transact that would otherwise re-submit the same source inputs. Assert that the probe rejects, the arm short-circuits, no `"already been included"` rejection is raised, and the daemon survives.

**Acceptance Scenarios**:

1. **Given** the daemon has just submitted a transact tx spending source inputs `{S1..Sk}` and lost the bearer before `MsgAcceptTx` arrived, **And** that tx actually landed, **When** the composer ticks the transact arm and the daemon re-builds a tx against any subset of `{S1..Sk}`, **Then** the probe reports at least one input as missing from the current tip's UTxO set, **and** the arm returns *indexer-not-ready* without calling submit.
2. **Given** all chosen source inputs are unspent at probe time, **When** the composer ticks the transact arm, **Then** the probe succeeds, **and** submit proceeds with semantics identical to before this feature.

---

### Edge Cases

- **Probe race**: between probe success and the submit primitive's wire write, a competing tx (not from this daemon) consumes one of the chosen inputs. The submit will then fail with the same `"already been included"` reason. This residual window is *narrower* than the pre-feature window but not zero. Out of scope for this spec; tracked as a follow-up only if the residual rate is high enough to fail acceptance.
- **No HD-index advance on short-circuit**: when the arm short-circuits on probe failure, the deterministic next-source counter MUST NOT advance — the same source set must be retryable on the next tick (the same source might genuinely be unspent again after a rollback).
- **Reconnect storm during probe**: the LSQ channel itself may be unavailable (bearer down, supervisor mid-reconnect). The probe call must surface this as an *indexer-not-ready* outcome, not a daemon crash, with the same retry semantics as a probe-says-spent outcome.
- **Probe under steady state (no fault injection)**: the probe MUST add no behavioural difference vs. pre-feature operation. The only observable difference is one extra LSQ round-trip per submit attempt.
- **Composition with the freshness gate (spec 037)**: the freshness gate runs first (skips the entire arm before any indexer read or tx construction). The probe runs *after* tx construction, immediately before submit. Both gates must compose cleanly — there is no scenario where the probe is consulted before the freshness gate.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: Before invoking the submit primitive in both the refill arm and the transact arm, the daemon MUST verify against the relay's current chain tip that every input the about-to-be-submitted tx is spending is still unspent.
- **FR-002**: If any input is reported missing from the current tip's UTxO set, the arm MUST short-circuit with the same *indexer-not-ready* response shape used by the freshness gate (spec 037), and MUST NOT invoke the submit primitive.
- **FR-003**: When short-circuiting on probe failure, the arm MUST NOT advance the HD-index counter (or any equivalent deterministic next-source selector). The same source set must be eligible for the next tick.
- **FR-004**: The probe MUST issue a single LSQ round-trip per submit attempt, querying all chosen inputs together (no per-input call).
- **FR-005**: When the probe succeeds, the arm MUST proceed with submit with semantics identical to before this feature — no change to construction, signing, or wire-side error handling.
- **FR-006**: If the LSQ channel itself is unavailable at probe time (e.g. bearer mid-reconnect), the probe MUST yield an *indexer-not-ready* outcome (not crash the daemon) and the arm MUST short-circuit per FR-002.
- **FR-007**: The probe MUST run after, not before, the freshness gate of spec 037. The two gates MUST compose without changing each other's semantics.
- **FR-008**: In steady state (probe always succeeds), end-to-end refill/transact behaviour MUST be unchanged from pre-feature within measurement noise.

### Key Entities

- **Pre-submit probe outcome**: a per-submit-attempt boolean (`all-inputs-unspent` vs. `at-least-one-spent-or-unknown`) derived from a single LSQ `GetUTxOByTxIn` query against the relay's current tip.
- **Indexer-not-ready response (probe-rejected variant)**: the not-applicable response shape inherited from spec 037, served when the probe fails. Composer-side retry semantics are unchanged.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A 1h `cardano_node_tx_generator` Antithesis run on https://github.com/cardano-foundation/cardano-node-antithesis/pull/98, against a pin that includes this fix, shows **0** `tx_generator_refill_submit_rejected` Always-assertion failures.
- **SC-002**: The same run shows **0** `tx_generator_transact_submit_rejected` Always-assertion failures.
- **SC-003**: The same run still triggers **at least 3000** `Disconnected/Reconnecting` events at the supervisor — i.e. the elimination of the false positive does not come from softening fault injection.
- **SC-004**: The new E2E spec passes locally: `nix develop -c cabal test e2e-tests --test-options='--match "tx-generator submit idempotence"'`.
- **SC-005**: In steady state (no fault injection), end-to-end refill/transact throughput is unchanged from pre-fix within measurement noise.

## Assumptions

- The relay's LSQ `GetUTxOByTxIn` query against the current tip is the right oracle for "is this input still spendable on the chain we are about to submit to". Mempool contents are intentionally not consulted — a tx already in the mempool that spends the same input would still cause submit to be rejected, but that case is much rarer than the post-reconnect race this spec targets, and tracking mempool contents would require a different mini-protocol.
- A single LSQ round-trip per submit attempt is acceptable overhead. The freshness gate already established that the daemon is not throughput-bound under realistic fault injection.
- Tracking in-flight tx IDs across reconnects (so a duplicate-submit *succeeds silently* rather than being skipped) is out of scope. If the residual rate of `"already been included"` rejections after this feature is non-zero, that follow-up is filed separately.
- Composer-side framing of `tx_generator_*_submit_rejected` is tracked at https://github.com/cardano-foundation/cardano-node-antithesis/issues/107 and is out of scope here. This spec only changes the daemon side.
- The refill arm's single-input shape and the transact arm's K-input shape can be unified behind one helper that accepts a `Set TxIn`.
