# Query the node at the indexer's block

## Consumer stories

1. As a client reading coins from an indexer, I use the slot and block hash
   returned by that snapshot to query the node at the same block. Several
   node queries share that acquired state even while the live chain advances.
2. As a client whose snapshot is too old or belongs to an unknown fork, I
   receive the node's named refusal and can request a fresh indexer snapshot.
   I never combine those coins with silently substituted tip state.
3. As an existing caller, I keep using one-shot and acquired-tip queries with
   their existing signatures and behavior.

## Authority and scope

Authority: [issue #218](https://github.com/lambdasistemi/cardano-node-clients/issues/218).
Planning base: `885447b10907c3d25084511083be98ef4357e26f`.
This intake changes only these four planning documents. Implementation starts
only after epic acceptance of the pushed draft PR. This document describes
required future behavior; it does not claim that behavior exists today.

Add a library callback API accepting `BlockPoint` (slot and block hash), issuing
`MsgAcquire (SpecificPoint p)`, and exposing `AcquireFailurePointTooOld` and
`AcquireFailurePointNotOnChain` separately. Run the callback only after a
successful acquisition. Every query through its handle uses that acquired
state until release. Refusal completes the call promptly without callback,
query, retry at tip, or implicit fresh snapshot.

Keep `queryLSQ`, `withAcquiredLSQ`, `queryAcquiredLSQ`, existing constructors,
Provider records and existing exports compatible. Keep connection-loss,
response-timeout and exception cleanup behavior. No new Provider-wide API,
indexer historical-read API, socket command or dependency is required.

## Required invariants

Every row is **BLOCKING**. Enforcement is planned, currently **NONE** for the
new behavior; existing tests cover only parts of compatibility/liveness.

| ID | Observable truth | Required evidence |
| --- | --- | --- |
| P1 | The acquire carries the complete requested point, including hash. | Node-free peer checks the exact target; real recent-point witness below. |
| P2 | All session answers describe P through later tip motion. | Multiple real acquired queries, point and UTxO contents, with P < Q before acquire and Q < R after acquire. |
| P3 | Too-old and unknown acquisitions return their respective named constructors; no tip fallback or callback. | Both real devnet refusals plus node-free callback/target trace and post-refusal recovery. |
| P4 | Existing tip APIs and public constructors retain their signatures and behavior. | Build existing consumers; existing suites and peer target/session regression tests. |
| P5 | The new point-session lifecycle handles caller cancellation at enqueue, acknowledgement wait, callback and release with bounded cleanup and later channel progress; exceptions, timeout and connection loss remain distinct from refusal. | Planned peer barriers at each blocking point assert caller-visible outcomes and subsequent channel health, including late acknowledgement; existing tip-path regression tests remain required. |
| P6 | Consumers pin node queries to the reported snapshot point and handle refusal explicitly. | Reviewed Haddock and consumer examples for both library and socket snapshots. |

## Acceptance

- Additive public session API and two distinguishable acquire refusals.
- Real local devnet demonstrates P-state answers after both required tip
  advances; a genuinely aged on-chain point and an unknown point each refuse
  by exact constructor. No skipped, pending or synthetic substitute cases.
- Consumer docs pair `readView` / socket `read_view` with the point API.
  `ivPoint` / response `point` identifies the current indexed snapshot, not
  an arbitrary requested historical read. Missing indexed point and node
  acquisition refusal are different failures.
- Full local CI and devnet suites pass, and existing CI jobs pass on the
  exact pushed implementation head. Source review and node-free tests do
  not establish live retention or live refusal semantics.
