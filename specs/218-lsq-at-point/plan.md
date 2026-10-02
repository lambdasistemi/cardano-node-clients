# Implementation plan

## Current surface and proposed API

`lib/Cardano/Node/Client/N2C/LocalStateQuery.hs` acquires `VolatileTip` for every
request. `recvMsgFailure` drops the refusal and waits for another request;
`Types.hs` has `LSQAcquire :: AcquiredLSQ -> TMVar () -> LSQRequest`.
Explicit sessions already have their own bounded queue and acquire boundary.
`BlockPoint` in `Client.Types` aliases `Ouroboros.Network.Block.Point Block`.

Proposed additive API in `N2C.LocalStateQuery`:

```haskell
withAcquiredLSQAt
    :: LSQChannel -> BlockPoint
    -> (AcquiredLSQ -> IO a) -> IO (Either AcquireFailure a)
```

Re-export the protocol's `AcquireFailure(..)` so callers can pattern-match
its two named constructors. Add a separate `LSQAcquireAt` request carrying
P, the handle and `TMVar (Either AcquireFailure ())`; leave the existing
`LSQAcquire` constructor and handle layout intact. Dispatch the new request
with `SendMsgAcquire (SpecificPoint p)`. A successful acknowledgement enters
the existing session loop; failure fills the acknowledgement with `Left`,
returns to idle and never calls the callback or reacquires another target.

Reuse the acquired handle, but verify the new lifecycle's cancellation safety
rather than assume that masking alone supplies it. Do not change tip behavior.
Timeout/connection loss remain exceptions, distinct from an acquire refusal;
callback exceptions propagate after bounded best-effort release. Ordinary
queries queued before/after a point session must never share its point state.
Preserve public Haddock and Apache-2.0 module headers. Inspect all pattern
matches on `LSQRequest` before adding the constructor.

## Planned cancellation and lifecycle checks

All checks here are **PLANNED / outstanding**. The source lead about legacy
`withAcquiredLSQ` cancellation is unexecuted; it neither proves a live defect
nor authorizes a legacy repair. Preserve P4. The implementation must satisfy
the new path's lifecycle property; this plan prescribes no cleanup algorithm.

Use the connected typed-protocol peer with deterministic barriers, not sleeps,
to cancel the caller at each reachable blocking point, including both sides
of request acceptance and successful acknowledgement. Observe that the barrier
was reached before cancelling; await the caller's actual result under a bound.
Cancellation must remain its asynchronous exception, never `Left` refusal,
successful return or swallowed timeout. Assert callback entry/exit counts and
peer acquire/query/release traces. After each case, unblock the peer and require
a fresh ordinary tip query on the same healthy connection to complete within
a declared bound with its expected answer; a leaked session, another caller's
timeout or runtime deadlock detection must not count as recovery.

| Blocking point | Discriminating planned checks and applicability |
| --- | --- |
| Enqueue | Saturate the request queue, cancel before acceptance and assert no subject acquire/callback; also cancel immediately after acceptance and require eventual cleanup and later tip-query success. Exercise enqueue stall/timeout and connection-generation loss with the same outcome/health assertions. A node refusal is possible only after acceptance, covered below. |
| Acknowledgement wait | Cancel after the peer receives the request, both before and racing a successful acknowledgement. Deliver the late success and prove it leaves no orphan session. Separately return each exact named refusal (zero callbacks), stall to timeout, and disconnect; assert distinct caller outcomes and later progress. |
| Callback / acquired queries | Cancel a blocked callback and a blocked handle query; also throw an ordinary callback exception, stall a query to timeout, and disconnect. Require the original exception/cancellation to propagate after bounded cleanup, no queries after release, and later progress. Acquisition refusal cannot occur after successful acknowledgement. |
| Release | Hold cleanup at its blocking boundary after callback success and after callback failure; cancel there, and separately stall or disconnect. Assert cancellation/primary exception preservation and bounded completion, plus later progress with no stranded session or duplicate release. Acquisition refusal has no acquired resource to release. |

For disconnected cases, observe the existing generation-failure exception,
then restore transport through the existing reconnect path and assert a fresh
query succeeds; do not claim progress on a dead connection. Cleanup failures
must not replace the primary callback exception or cancellation with a named
acquire refusal. Record bounds, reached barriers, outcomes and recovery traces.
No cancellation residual is proposed: implementation acceptance still requires
these checks to execute and discriminate abandonment at every applicable point.

## Real recent-point witness

Use a dedicated devnet with two independently running N2C connections. The
observer/submission connection must remain usable while the subject connection
is acquired: querying live tip on the same LSQ queue would deadlock. Reuse
`E2E.Devnet`, `Setup`, `ChainPopulator` and the established Conway query and
transaction patterns in `E2E.ProviderSpec` / `E2E.AssetQuerySpec`.

1. Obtain a non-origin P and baseline UTxO map UP for a test-owned address
   from one independent volatile acquisition. Confirm a spendable witness
   output exists; keep its actual TxIn and complete TxOut as the oracle.
2. Submit a transaction consuming that output and producing changed outputs.
   Await its inclusion through ChainSync/independent node queries. Record
   Q and UQ in one observer acquisition; require P < Q by observed block
   sequence, and UP /= UQ. Ensure P is still inside the retention window.
3. Start `withAcquiredLSQAt subject P`. Entering its callback is the acquire
   acknowledgement barrier. No subject query precedes the next advance.
4. Through the independent connection, submit a second controlled change and
   observe a later R and UR, requiring Q < R and UR /= UP (also UR /= UQ).
5. Only now query `GetChainPoint` and Conway `GetUTxOByAddress` through the
   acquired handle, repeating both. Require each point equals the observed P
   and each complete UTxO map equals UP, including the consumed witness TxIn
   and original output. Verify observer state remains different. Release,
   then show a fresh tip session observes the changed state.

Bounds and readiness failures fail the test explicitly. Record P/Q/R hashes,
block numbers, transaction inclusion, state contents and acquisition/query
ordering; labels supplied by the caller are not expected state. The same
compiled devnet case must fail if only the production specific target is
replaced by `VolatileTip`: acquisition would pin a state at/after Q with the
witness output already consumed. It must also fail on per-query reacquisition.
These controls are future work, not executed intake evidence.

For this transaction witness, copy genesis into the test's own temporary
fixture and use `slotLength = 1` second, retaining `securityParam = 10` and
`epochLength = 100`. This increases coordination time without changing the
number of retained blocks; shared genesis stays unchanged. Use observed
blocks and inclusion barriers, never sleep as proof. If coordination cannot
keep P available, report the failed prerequisite rather than weakening the
oracle. Bound the entire scenario and clean up both clients and node.

## Retention and real refusals

The pinned library is `ouroboros-consensus-3.0.1.0`; the flake node is 11.0.1
(revision `97036a66bcf8c89f687ae57a048eecc0389977ef`). Default devnet genesis
has k=10, slotLength=0.1, activeSlotsCoeff=1; `node-config.json` specifies no
LedgerDB override. Node configuration defaults to V2InMemory. Pinned sources:
`Storage.LedgerDB.Args.praosGetVolatileSuffix` retains k blocks and the anchor;
V2 `getVolatileLedgerSeq` applies that suffix when opening a state reference;
`openStateRefAtTarget` returns PointTooOld for a missing point strictly below
the anchor slot, otherwise PointNotOnChain. The LSQ server maps those errors
to the two required constructors. This source fact guides the witness;
only execution against the launched node establishes live refusal evidence.

On a separate default-speed devnet, capture a real non-origin on-chain Pold,
prove it is initially acquirable, release, then count strictly more than k
subsequent selected blocks (not slots or elapsed time). Independently acquire
`ImmutableTip` using a test-owned protocol client over the real Unix socket,
query its chain point I, and require slot(Pold) < slot(I). Attempt a new point
session at Pold and require exactly `Left AcquireFailurePointTooOld`.
Do not use Origin, a fabricated ancient point or an open pinned session as
an old-point substitute. The immutable anchor itself can still be acquired.

For the unknown case, construct a different valid-length hash at an observed
recent slot (or a future slot safely above I). Confirm it is not an observed
chain point, then require exactly `Left AcquireFailurePointNotOnChain`.
Do not classify an ancient fabricated point as the unknown witness. Check
callback count remains zero for both refusals and a later ordinary query
succeeds on the subject connection. A timeout is not a named refusal.

## Unit, wiring and consumer docs

Extend `test/Cardano/Node/Client/N2C/LocalStateQuerySpec.hs` using its existing
connected typed-protocol peer. Check exact SpecificPoint (same-slot different
hash included), both failures, no callback/query on failure, queue isolation,
multiple queries, release on success/exception and existing liveness semantics.
These node-free tests prove client transitions, not a node's retention policy.

Add dedicated `test/Cardano/Node/Client/E2E/LocalStateQueryAtPointSpec.hs`,
register it in `test/main.hs` and the Cabal e2e component. Use the existing
e2e app/CI job; no parallel acceptance runner is needed. Keep all three live
cases discoverable under the future match label `LocalStateQuery at point`.

Update `docs/modules/n2c.md`, `docs/usage/utxo-indexer.md` and API Haddock with
an example reading a view, converting `(SlotNo, BlockHash)` / socket hex hash
to `BlockPoint`, handling both refusals, and querying only via the supplied
handle. Validate hash bytes and preserve slot/hash together. On refusal,
refresh the complete indexer view and explicitly retry a new node session;
never keep old coins while replacing only the node view. #210/#220 already
provide current materialized snapshots. No changes in consuming repositories.

## Remaining implementation checks

Verify the protocol type's export location and exact constructor field types
against pinned packages while compiling; confirm test-local slower genesis
forges and the two transaction barriers fit its retained-block window. Capture
the actual launched node version/backend and immutable anchor at runtime.
These are prerequisites to the planned tests, not waivers of acceptance.
