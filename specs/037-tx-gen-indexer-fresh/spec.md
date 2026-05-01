# Feature Specification: Gate tx-generator arms on indexer freshness after N2C reconnect

**Feature Branch**: `037-tx-gen-indexer-fresh`
**Created**: 2026-05-01
**Status**: Draft
**Input**: User description: "Gate the tx-generator daemon's refill and transact arms on indexer freshness after N2C reconnect (issue #109)"
**Tracks issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/109
**Depends on (already merged)**: https://github.com/lambdasistemi/cardano-node-clients/pull/105
**Related spec**: `specs/035-indexer-n2c-reconnect/` (introduced `rsUpstream`, `UpstreamConnected`, `rsReady`)
**Antithesis report (regression evidence)**: https://cardano.antithesis.com/report/sgGPKwEUgpMFBkdN3QMH1MDn/CVALsMOlHQdIyvQsc0sKyxZ79mapUIksHP-v0XZcVds.html

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Refill arm never submits a tx built from stale post-reconnect UTxOs (Priority: P1)

A `cardano-tx-generator` daemon is supervising its N2C bearer via the auto-reconnect loop introduced in spec 035. The relay is restarted under fault injection. As soon as the new bearer is established and the LSQ probe answers, the supervisor flips upstream status to *connected*. During the short window before the embedded chain-sync follower has caught the indexer's UTxO view back up to the new tip, the indexer's local view is *stale*: it still reflects the chain state from before the bearer died. The composer ticks into this window and asks the daemon to refill the faucet.

The daemon must refuse to issue a refill submission until its own UTxO view is provably caught up past the reconnect anchor — even though the bearer is "connected" and `rsReady` (within N slots of tip) might already be true. The composer should see a defined "indexer not ready" response and try again on the next tick, rather than the daemon submitting a refill tx whose inputs the post-reconnect chain has already spent.

**Why this priority**: This is the failure mode that trips the `tx_generator_refill_submit_rejected` Always-assertion under Antithesis (111 hits across 95 forks on 329a599). The submission is correctness-preserving — the relay rejects with `ConwayMempoolFailure "All inputs are spent"` — but the assertion is framed "should never happen", so eliminating the rejected-submission window is the bar to clear before the run goes green.

**Independent Test**: Deterministic: drive the daemon's state directly. Force `setUpstreamStatus UpstreamConnected` (the supervisor's post-reconnect entry point) without delivering a chain-sync `RollForward` afterwards, then run the refill arm. The arm must return *not-applicable / indexer-not-ready* and must not call the submit primitive. Then deliver one `RollForward` and re-run: the arm proceeds normally.

**Acceptance Scenarios**:

1. **Given** the supervisor has just flipped upstream status to *connected*, **And** no `RollForward` has been applied since that flip, **When** the composer ticks the refill arm, **Then** the daemon returns *indexer-not-ready* (a not-applicable response) **and** does not submit any tx.
2. **Given** the supervisor has flipped upstream status to *connected* **And** at least one `RollForward` has been applied since that flip, **When** the composer ticks the refill arm, **Then** the daemon proceeds with the normal refill flow.
3. **Given** the daemon was already in steady state with upstream connected and the indexer fresh, **When** an unrelated tick fires the refill arm, **Then** behaviour is unchanged from before this feature (no regression).

---

### User Story 2 - Transact arm never queries the indexer for source UTxOs in the stale window (Priority: P1)

Same setup as US1: post-reconnect, before chain-sync has rolled forward. The composer ticks the *transact* arm, which would normally pick a source from the indexer and build a fan-out tx for it.

The daemon must refuse to pick a source from a stale UTxO view. The composer should see *not-applicable* and retry on the next tick.

**Why this priority**: The same Antithesis run produced 136 `no-pickable-source` outcomes in this window, tripping `tx_generator_population_did_not_grow`. The fix and the gating logic are the same as US1; pairing them avoids two separate freshness gates.

**Independent Test**: Same deterministic fixture as US1, but exercise the transact arm. Without a post-reconnect `RollForward`, the arm must return *indexer-not-ready* and must not call the indexer's UTxO query primitive. After one `RollForward`, the arm must run normally.

**Acceptance Scenarios**:

1. **Given** upstream just flipped to *connected* and no `RollForward` has been applied since, **When** the composer ticks the transact arm, **Then** the daemon returns *indexer-not-ready* and does not call the indexer's source-UTxO query.
2. **Given** at least one post-reconnect `RollForward` has been applied, **When** the composer ticks the transact arm, **Then** the daemon proceeds with the normal source-pick flow.

---

### User Story 3 - Indexer freshness is observable and Sometimes-thresholds tolerate slow recovery (Priority: P2)

Under heavy fault injection there will be windows where the daemon serves *not-applicable* for many composer ticks in a row — that is the correct answer, not a regression. Operators inspecting an Antithesis run need (a) a way to see *why* a tick was not-applicable (refill/transact short-circuited because indexer was stale, vs. some other reason), and (b) the composer's `tx_generator_*_landed` Sometimes-assertion thresholds set high enough that long not-applicable streaks during reconnect storms do not trip them.

**Why this priority**: Without observability and threshold tuning, the fix succeeds at eliminating Always-assertion failures but creates a different class of false alarms. P2 because the P1 stories already deliver the correctness fix in isolation.

**Independent Test**: Run a fault-injection scenario that reconnects N times. Inspect the daemon's structured output: every short-circuited refill/transact tick must carry an `indexer-not-ready` reason. The Sometimes-assertion thresholds, after this PR's adjustment, must allow a 1h `cardano_node_master` run to pass even when 4000+ reconnect events occur.

**Acceptance Scenarios**:

1. **Given** the daemon short-circuits a refill or transact tick because of indexer staleness, **When** the operator inspects the daemon output for that tick, **Then** the response carries a distinguishable reason (e.g. `indexer-not-ready`) separate from other not-applicable causes.
2. **Given** a 1h `cardano_node_master` Antithesis run with the supervisor producing 4000+ disconnect/reconnect events, **When** the run completes, **Then** zero `tx_generator_refill_submit_rejected` and zero `tx_generator_population_did_not_grow` Always-assertion failures are reported, **and** the `tx_generator_*_landed` Sometimes-assertion thresholds are met.

---

### Edge Cases

- **Reconnect storm**: upstream flips to *connected* repeatedly, with each flip occurring before the prior `RollForward` has arrived. Indexer freshness must remain false across the entire storm and only flip true after a `RollForward` that follows the *last* upstream flip — never carry over freshness from a previous connected episode.
- **Reconnect with no new blocks for an extended period**: the relay reconnects but the chain genuinely produces no new block for many slots. The arms remain short-circuited until a `RollForward` is observed; the operator sees consistent *indexer-not-ready* responses, which is the desired behaviour (better to be silent than to submit against a stale view).
- **Daemon cold start**: on first startup the supervisor flips upstream to *connected* once. The same gate applies: arms wait for the first post-startup `RollForward` before serving real responses. This is a no-op concern in practice because the daemon's own readiness gate (`rsReady`) already covers cold start, but the gating logic must compose cleanly.
- **`rsReady` is true while indexer is fresh-after-reconnect = false**: the two gates are orthogonal. Both must be true for an arm to proceed.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The daemon MUST track an *indexer-fresh* status, distinct from `rsUpstream` (bearer connection state, defined in spec 035) and `rsReady` (within-N-slots-of-tip, defined in spec 035).
- **FR-002**: Whenever the supervisor flips upstream status to *connected* (via the call site equivalent to `setUpstreamStatus UpstreamConnected`), *indexer-fresh* MUST be set to false.
- **FR-003**: *Indexer-fresh* MUST be set to true only after the embedded chain-sync follower has applied at least one `RollForward` event since the most recent transition to *connected*. Older RollForwards observed before the most recent reconnect MUST NOT count.
- **FR-004**: The refill arm MUST short-circuit with an *indexer-not-ready* response while *indexer-fresh* is false. It MUST NOT call the submit primitive in that state.
- **FR-005**: The transact arm MUST short-circuit with an *indexer-not-ready* response while *indexer-fresh* is false. It MUST NOT call the indexer's source-UTxO query primitive in that state.
- **FR-006**: The *indexer-not-ready* response surfaced to the composer MUST be of the same general shape as other not-applicable responses (so the composer's existing retry-on-tick behaviour applies unchanged) but MUST carry a reason distinguishable from other not-applicable causes (e.g. "no-pickable-source" remains a separate reason).
- **FR-007**: The composer's Sometimes-assertion thresholds for `tx_generator_*_landed` MUST be raised to a level that tolerates not-applicable streaks of the duration that arise from realistic fault-injection workloads, while still being tight enough to detect real regressions.
- **FR-008**: When *indexer-fresh* is true and the other gates allow it, the refill and transact arms MUST behave exactly as before this feature (no behaviour change in the steady state).
- **FR-009**: The indexer's chain-sync streaming behaviour itself MUST NOT change — it continues to stream forward as defined in spec 035; this feature only gates the daemon's *reads*.

### Key Entities

- **Indexer-fresh status**: a boolean flag owned by the daemon. False between any "upstream connected" event and the first subsequent applied `RollForward`. Independent of `rsReady`.
- **Reconnect anchor**: implicitly, the chain position at which the most recent upstream-connected event occurred. The flag flips back to true when the indexer's applied chain has advanced past this point.
- **Not-applicable response (indexer-not-ready)**: the response served by a short-circuited arm. Distinguishable in observability output from other not-applicable causes.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A 1h `cardano_node_master` Antithesis run on a downstream pin bump with this fix shows **0** `tx_generator_refill_submit_rejected` Always-assertion failures.
- **SC-002**: The same run shows **0** `tx_generator_population_did_not_grow` Always-assertion failures.
- **SC-003**: The same run still triggers **at least 4000** disconnect/reconnect events at the supervisor — i.e. the fault-injection coverage is not degraded by the fix.
- **SC-004**: The same run satisfies the (newly tuned) `tx_generator_*_landed` Sometimes-assertion thresholds.
- **SC-005**: In steady state (no fault injection), end-to-end refill/transact throughput is unchanged from pre-fix within measurement noise.
- **SC-006**: Every short-circuited refill/transact tick is attributable from the daemon output to the *indexer-not-ready* cause, distinct from other not-applicable causes.

## Assumptions

- The supervisor's "upstream connected" transition (introduced by PR #105) is the right hook for resetting freshness — the LSQ probe completing is *not* sufficient on its own to declare freshness, since chain-sync runs on a separate mini-protocol and is what actually advances the indexer's UTxO view.
- One `RollForward` after reconnect is sufficient to declare freshness. Rationale: the indexer applies blocks in chain order, so any `RollForward` observed after the most recent reconnect implies the chain-sync mini-protocol has resumed and the indexer has caught past whatever stale state remained from the previous connection. The existing `rsReady` gate already covers tip-distance, so this feature does not need to additionally wait until tip is reached.
- The composer treats *indexer-not-ready* responses identically to existing not-applicable responses for the purpose of retry-on-next-tick. No composer-side change is required for retry behaviour; only the assertion thresholds change.
- Composer-side Always-assertion adjustments (B/C/D) are tracked separately at cardano-foundation/cardano-node-antithesis #105, #106, #107 and are out of scope here. Only the *Sometimes*-thresholds for `tx_generator_*_landed` are touched in this repo.
- The indexer's chain-sync re-sync semantics (always streaming forward) are correct as-is and out of scope.
