# Contract: Arm-side freshness gate

**Spec**: [../spec.md](../spec.md)
**Plan**: [../plan.md](../plan.md)
**Data model**: [../data-model.md](../data-model.md)

## Scope

This contract describes the arm-side gating behaviour added by issue #109. It is internal to the daemon process — no NDJSON message changes, no new wire field, no new failure reason.

## Refill arm contract

Before the existing `runRefillArm` is invoked, the daemon takes a snapshot of `ReadyState` and:

| `rsIndexFresh` | Action                                                                  | Response                       |
|----------------|-------------------------------------------------------------------------|--------------------------------|
| `False`        | Short-circuit. Do **not** query LSQ. Do **not** call `submitTx`.        | `RefillFail IndexNotReady`     |
| `True`         | Proceed exactly as today. The existing `E.handle ConnectionLost` wrap and `runRefillArm` body run unchanged. | (per existing arm behaviour)   |

NDJSON shape on the wire (unchanged from existing): `{"ok": false, "reason": "index-not-ready"}`.

## Transact arm contract

Identical structure to refill:

| `rsIndexFresh` | Action                                                                  | Response                         |
|----------------|-------------------------------------------------------------------------|----------------------------------|
| `False`        | Short-circuit. Do **not** query LSQ for source UTxOs.                   | `TransactFail IndexNotReady`     |
| `True`         | Proceed with `runTransactArm` as today.                                 | (per existing arm behaviour)     |

NDJSON shape on the wire (unchanged): `{"ok": false, "reason": "index-not-ready"}`.

## Composability with existing gates

The freshness gate is **orthogonal** to the existing `rsReady` (within-N-slots-of-tip) gate and to the supervisor-managed `rsUpstream` (bearer state). The decision matrix at the top of each arm:

| `rsUpstream`           | `rsIndexFresh` | `rsReady`  | Arm behaviour                                                        |
|------------------------|----------------|------------|----------------------------------------------------------------------|
| `UpstreamDisconnected` | (any)          | (any)      | `IndexNotReady` (existing — encoder enforces this on the wire too)   |
| `UpstreamConnected`    | `False`        | (any)      | `IndexNotReady` (NEW — this PR)                                      |
| `UpstreamConnected`    | `True`         | `False`    | The existing arm logic runs; whether it emits `IndexNotReady` or proceeds depends on the arm's existing tip/ready handling. |
| `UpstreamConnected`    | `True`         | `True`     | Arms run normally (steady state, unchanged behaviour).               |

This PR adds only the second row.

## Read-sequence guarantees

- The freshness check uses `readTVarIO`, not `atomically`. It is non-blocking: the arm tick either short-circuits or proceeds immediately.
- The check happens *before* the existing `E.handle ConnectionLost` wrapper. If the bearer dies between the freshness read and the LSQ call inside the arm, the existing `ConnectionLost` handler still translates to `IndexNotReady` — the two paths produce the same wire response.
- No invariant is required between the freshness check and subsequent LSQ activity; staleness is a *read*-side concern only, and a stale read followed by a tx submission against the relay is what the existing relay-side rejection ultimately catches anyway. The gate is a coverage improvement, not a correctness guarantee.

## Out-of-scope contracts

- **Composer-side `tx_generator_*_landed` Sometimes thresholds**: out of scope for this repo. Filed as a companion change in `cardano-foundation/cardano-node-antithesis` (cross-link from issue #109 once the companion PR is opened).
- **Composer-side Always-assertions B/C/D**: tracked at cardano-foundation/cardano-node-antithesis #105/#106/#107.
- **Indexer chain-sync re-sync semantics**: unchanged. The follower keeps streaming forward; this PR only gates the arm reads.

## Backwards compatibility

The wire protocol is unchanged. Older composers that already retry on `index-not-ready` will see slightly more `index-not-ready` responses during reconnect storms but otherwise no behavioural difference. Older composers that did *not* retry on `index-not-ready` would already have been broken by the existing daemon (this is a pre-existing wire response, not a new one).
