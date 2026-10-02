# Decisions and reasons — #220 proposal

All choices here are provisional until epic intake acceptance. Issue #220 is
authoritative; these proposals do not approve implementation or relax its scope.

| Decision | Reason |
|---|---|
| Add `read_view` with a direct nonempty array. | Mirrors the library batch with one key and no requested-point/timeout envelope. |
| Use existing `utxos_at` / `utxos_with_asset` query keys. | Keeps lookup vocabulary and asset validation familiar. |
| Success is one `point` plus ordered `results`, each keyed by query kind. | Position correlates repeated queries; the kind prevents consumers confusing address members with asset holders. |
| Keep duplicates and permit singleton batches. | Matches `NonEmpty ReadQuery` without imposing artificial uniqueness or a minimum of two. Tests still require several queries. |
| Reuse current address and asset-member encodings. | Preserves CBOR bytes, decimal quantities, datum and original creation provenance without creating a second representation. |
| Validate the entire batch before one `readView` invocation. | Prevents partial execution or success when a later element is invalid. |
| Use `invalid_read_view` with diagnostic `detail` for any invalid new batch. | One refusal covers address, asset and envelope failures; `invalid_asset_query` remains unchanged for the legacy endpoint. |
| Require exact keys only after legacy parsers decline. | Strict new input remains compatible with old parsers' acceptance of extra or ambiguous keys. |
| Append the batch parser after the asset parser. | Even legacy invalid-asset answers are accepted requests whose bytes and precedence must survive. |
| Preserve raw hex address acceptance, including empty bytes. | New address semantics would exceed the additive socket contract. |
| Forward all four existing unavailability reasons without partial answers. | Consumers distinguish unavailable state from a real available no-match result; address-only views share the library readiness gate. |
| Refuse undecodable asset datum bytes as `inconsistent`. | Existing asset encoding already refuses these; inventing datum would break output integrity. |
| No batch disclosure, requested point, freshness or coverage fields. | Keeps #220 bounded; legacy asset disclosure remains byte-compatible. The batch reports actual indexed state, not completeness or synchronization. |
| Keep the library API and implementation unchanged. | #210 already implements the required one-snapshot mechanism; the missing surface is the socket. |
| Delegate real reads through a deterministic test wrapper and advance before its first return. | Acknowledged mutation separates real snapshots reliably without timing sleeps or fake responses; normal dispatch has already materialized all queries atomically. |
| Fault only the new socket branch into singleton view calls. | Proves the server uses one view; the inherited library fault proves a different layer and cannot replace this check. |
| Use a pure ledger-output history as the contents oracle. | A separately stamped point or a second production read cannot establish that all answers describe one state. |
| Keep a baseline Server copy as a test-only byte oracle. | Runtime baseline responses cover all four legacy endpoints and parser fallback; static expected strings alone risk duplicating the changed encoder. |
| Stabilize baseline/candidate disclosure with future last-progress time. | Existing age clamps to zero; byte comparison does not discard or normalize time fields. |
| Add the fault via existing Nix/runner machinery and a downstream CI job. | The guard must execute in CI and distinguish semantic rejection from setup failure; no second untracked acceptance harness. |
| Ship one coherent implementation commit after acceptance. | Parser, dispatcher, proof, fault wiring and docs describe one additive behavior; no independently releasable split is demonstrated. |

## Reliance, severity and honest limits

The proposed BLOCKING rows in `spec.md` constrain consumer transaction inputs.
Enforcement in this planning commit is NONE: no new socket behavior, new guard
or new fault exists yet. Source inspection identifies dependencies only.

- The library returns one materialized point/results view on both backends,
  retaining order, duplicates and creation provenance. Inherited library tests
  and `fault-view-snapshot-binding` remain required; socket tests cannot repair
  or silently redefine this contract.
- The existing fault runner distinguishes assertion mismatch from exception,
  missing/ambiguous/pending example and setup failure. The new guard must keep
  handshake failures on that setup path, not count them as atomicity failures.
- The proof domain is ledger-reachable. A transaction ID commits to its outputs;
  re-creating a TxIn at another address or with new bytes is an invalid fixture.
  Corrupt storage fixtures are separate refusal tests, not reachable atomicity
  evidence. Same-slot forks are distinguished by block hash.
- The reported indexed point does not promise current chain tip, full address
  coverage, or consumer-side requested-point matching. No consumer or preprod
  acceptance follows from local socket tests or repository CI.

## Acceptance and change control

Epic-owner intake acceptance must freeze the chosen request/error spelling,
ordered correlation, strict-key rules, snapshot witness and planned CI gate.
If implementation cannot deliver the controlled-advance witness, or discovers
a library/API defect or a required file outside its accepted fence, return the
exact evidence and scope question to the parent before changing the contract.
Missing feature/fault commands have not been run or falsified at intake.
Documentation accuracy is ADVISORY but remains a required deliverable; it is
not an optional residual simply because its severity differs from atomicity.
