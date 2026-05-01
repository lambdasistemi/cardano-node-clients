# Phase 0 — Research: Indexer-fresh gate for tx-generator arms

**Spec**: [spec.md](spec.md)
**Plan**: [plan.md](plan.md)

## Decision 1 — Where to track freshness

**Decision**: Add `rsIndexFresh :: !Bool` to the existing `ReadyState` record in `lib/Cardano/Node/Client/TxGenerator/Daemon.hs:217-223`, owned by the same `TVar ReadyState` that `setUpstreamStatus` and `updateReady` already mutate.

**Rationale**:
- One `TVar`, three orthogonal flags (`rsUpstream`, `rsReady`, `rsIndexFresh`). Keeps all readiness state in one atomic snapshot, so an arm tick can read all three with a single `readTVarIO`.
- `setUpstreamStatus` (Daemon.hs:322) and `updateReady` (Daemon.hs:1089) already hold the only two write paths to `readyVar`. Adding the new flag lets us reuse both without inventing a third writer.

**Alternatives considered**:
- *Separate `TVar Bool` for freshness*: rejected. Two `TVar`s mean two read points, race window between them, and a duplicated invariant (the encoder enforces `UpstreamDisconnected => ready=false` on the wire — defense in depth). Single-source-of-truth wins.
- *Derive freshness from `rsProcessedSlot` against a captured anchor*: rejected. It works, but it requires us to also track the slot at which the most recent `UpstreamConnected` flip occurred, plus monotonicity reasoning across rollbacks. A boolean owned by both writers is simpler and exactly captures the spec invariant ("flip false on connect, flip true on first subsequent RollForward").

## Decision 2 — Where to flip false (reset on reconnect)

**Decision**: Inside `setUpstreamStatus`'s `UpstreamConnected` branch (Daemon.hs:325-326), set `rsIndexFresh = False` *unconditionally* on every flip into the connected state. Today that branch only updates `rsUpstream`; we extend it to also clear freshness.

**Rationale**:
- The supervisor calls this entry point on (a) initial connect, (b) every successful reconnect after a `UpstreamDisconnected` episode. Both correctly want freshness false.
- Clearing on every connect (even back-to-back, with no intervening disconnect, if the supervisor ever spuriously re-confirms) is safe: it only delays the arm by one `RollForward`. The opposite mistake — letting freshness persist across a disconnect/connect cycle — is the exact bug being fixed.
- The spec edge case "reconnect storm" requires that freshness *never* carry over from a previous connected episode. Clearing here, in the only entry point used by the supervisor, satisfies that.

**Alternatives considered**:
- *Only flip on the disconnect side and leave UpstreamConnected unchanged*: rejected. It works for the common case, but a fast disconnect/connect/disconnect/connect that lands a `RollForward` between the first connect and the second disconnect would leak a fresh state into the second connection. Resetting on every Connected is unconditional and immune to ordering.

## Decision 3 — Where to flip true (clear on first post-reconnect block)

**Decision**: Inside `updateReady` (Daemon.hs:1089), which is called exclusively from the chain-sync `Follower`'s `rollForward` callback (Daemon.hs:1062-1068), after the indexer has already applied the new block (`applyAtSlot idx slot bh ops` at Daemon.hs:1066). Add `rsIndexFresh = True` to the `modifyTVar'` block at Daemon.hs:1105-1110.

**Rationale**:
- The follower's `rollForward` runs *after* `applyAtSlot`. By the time we set `rsIndexFresh = True`, the indexer's UTxO view has already advanced past the block. That is exactly the freshness invariant the spec demands: "the indexer state has advanced past the reconnect anchor".
- We deliberately do not require the rolled-forward slot to be ≥ the slot at the moment of reconnect. The chain follows chain order; any post-reconnect `RollForward` implies the chain-sync mini-protocol has resumed at the new tip and the indexer's view is now consistent with the live relay's view at *some* point on or after the reconnect anchor. Tip-distance is already gated by `rsReady`.
- `updateReady` is also called on `rollBackward`-then-`rollForward` sequences (the reconnect intersector path uses the same follower). A rollback before the first forward would leave `rsIndexFresh = False`; only the first actual forward flips it true. Correct.

**Alternatives considered**:
- *Flip true at intersection (`intersectFound`)*: rejected. Intersection only proves the relay has agreed on a starting point; it does not prove the indexer has advanced. A relay reconnect that re-intersects at the same point as before the disconnect would set freshness true while the indexer's UTxO view is still exactly the stale view. Wrong.
- *Flip true after N blocks*: rejected. One block suffices to prove chain-sync has resumed; more blocks just extends the not-applicable window.

## Decision 4 — Where to apply the gate

**Decision**: Wrap the existing `doRefill` and `doTransact` callbacks in `runDaemonWithTracer` (Daemon.hs:399, 419) with a freshness check at the *top*, before the existing `E.handle ConnectionLost` wrapper. If `rsIndexFresh` is false, return `RefillFail IndexNotReady` / `TransactFail IndexNotReady` immediately, without entering `runRefillArm` / `runTransactArm`.

**Rationale**:
- Top-level wrapping keeps the freshness logic in one place (the daemon's wiring), not duplicated inside each arm.
- Both arms already have `IndexNotReady` as a wire-stable failure reason (Types.hs:136, serialised as `"index-not-ready"` at Types.hs:146). The composer already retries on this reason — no composer-side change required.
- `doRefill` / `doTransact` already exist as the right wrapping seam (they own the `E.handle ConnectionLost` translation today). Adding a freshness short-circuit at the same level is idiomatic.

**Alternatives considered**:
- *Inside each arm's body*: rejected. Two write sites, easy to drift, harder to reason about as a single gate.
- *In `Server.hs`'s `handleConn`*: rejected. The server is wire-shape-only; per-request semantic gating belongs to the daemon wiring that owns the `TVar`.

## Decision 5 — Snapshot vs. STM retry

**Decision**: The freshness check uses `readTVarIO` (a non-blocking snapshot), not `atomically retry`. If `rsIndexFresh` is false at the moment of the check, the arm short-circuits immediately; the composer retries on the next tick.

**Rationale**:
- The spec is explicit: the daemon should serve a *not-applicable* response and let the composer retry. Blocking inside the arm would defeat the composer's tick model and could pile up requests across reconnect storms.
- Non-blocking is also what the existing code does for `rsReady` (the readyResponseFrom path returns `ready=false` rather than blocking).

## Decision 6 — Initial value of `rsIndexFresh`

**Decision**: `False`. The current `initialReady` (Daemon.hs:225-232) already starts with `rsUpstream = UpstreamConnected` (a polite lie that's corrected the first time the supervisor reports its real status), and starting with `rsIndexFresh = False` means the daemon serves *index-not-ready* on cold start until the first `RollForward` lands. This composes correctly with the existing cold-start behaviour and the existing `rsReady = False` initial.

**Rationale**:
- Cold start is operationally identical to a reconnect with no prior state. The same gate that protects against stale-after-reconnect protects against not-yet-synced-on-cold-start.
- `rsReady = False` already holds at boot, so without the new gate the arms would have already been blocked by tip-distance; the freshness gate is strictly redundant in cold start in practice but symmetric in semantics, which is what we want.

## Decision 7 — Threshold bumps for `tx_generator_*_landed`

**Decision**: Out of scope for this repository. The Sometimes-assertions live in the composer at `cardano-foundation/cardano-node-antithesis` (per spec 034's `contracts/control-wire.md`). The threshold bumps for `tx_generator_*_landed` will be filed as a companion PR in that repo.

**Rationale**:
- The spec's FR-007 names a contract enforced in another codebase. Splitting it preserves repo ownership boundaries.
- Acceptance criteria SC-001..SC-004 will be verified by running the 1h `cardano_node_master` Antithesis workload against a downstream pin bump that picks up *both* this repo's gate and the companion PR's threshold tweaks.

**Action item**: open the companion issue/PR in `cardano-foundation/cardano-node-antithesis` to track the threshold bump; cross-link from issue #109 once filed.

## Open question: testing the gate without a real reconnect

The cleanest deterministic test would force a "reconnect happened, no `RollForward` yet" state. Two paths considered:

- **Real reconnect via fault injection**: stop+start the relay container. Authentic, but timing-sensitive and slow.
- **Direct manipulation via `setUpstreamStatus`**: requires exporting `setUpstreamStatus` (or a test-only "reset freshness" helper) from `Daemon.hs`, breaking encapsulation.

**Resolved**: prefer a real reconnect E2E (consistent with constitution principle II — no mocks for node communication). The supervisor already drives this path; we just need to assert that during the post-reconnect window the arm response is `index-not-ready` and not `submit-rejected`. The existing `TxGeneratorRestartSpec.hs` is the right neighbour to extend or template from.
