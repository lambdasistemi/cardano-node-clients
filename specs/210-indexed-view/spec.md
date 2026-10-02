# Mandate v1 — #210 indexed read view

Authority: [#210](https://github.com/lambdasistemi/cardano-node-clients/issues/210),
read in full on 2026-10-02; epic #199 V1–V4/C4 and the ticket brief.
Base: `7f9d620e49e1e4da294a79537a51e951c7f93888`. Draft PR: #217.
Status: proposed intake; no implementation authority until epic acceptance.

## Stories and requirements

- R1 / V1: an embedder supplies several address and asset queries and receives
  one immutable result view with the slot and block hash it was read at.
  The point, completeness state, all answers and asset provenance belong to
  one storage transaction: one RocksDB snapshot or one in-memory state read.
- R2 / V2: under concurrent apply and rollback, every answer equals the
  independent model at the reported point. Separate-snapshot lookups must
  fail that same behavioral assertion under a controlled production fault.
- R3 / V3: an empty/restoration-only store or an incomplete/degraded/rebuilding
  asset index refuses the whole view with existing `AssetQueryUnavailable`.
  No partial view or successful empty answer conceals unavailability. This
  applies to address-only views too; ordinary `snapshotAt` remains available.
- R4 / V4: a socket client names P and supplies several queries in one
  additive request. All answers use one snapshot whose point equals P.
  Behind P, wait for a bounded interval; past P, at another hash at P's slot,
  or still behind at expiry, refuse with a named error and both points.
  An unavailable index uses R3 instead of inventing an indexed point.
- R5 / C4: `snapshotAt` keeps its signature and behavior. Request and response
  bytes for `utxos_at`, `ready`, `await`, `utxos_with_asset` remain unchanged.
- R6: `docs/usage/utxo-indexer.md` documents the library view, its point,
  unavailability, and, if S2 is retained, the socket schema and refusal rules.

## Invariants

| ID | Observable obligation | Failure witness |
|---|---|---|
| I210-ONE | point and all address/asset results belong to one transaction | any result differs from independent model at view point |
| I210-POINT | socket success point equals requested slot AND hash | success at another point under removed point check |
| I210-BOUND | behind-P waiting ends within the documented bound; ahead/fork refuses promptly | unbounded wait or response from another point |
| I210-AVAILABLE | unavailable stores return existing typed refusal for the whole view | successful empty/partial view on unavailable store |
| I210-COMPAT | existing public read and four legacy wire contracts remain compatible | existing regression spec fails or bytes differ |
| I210-PROVENANCE | asset match bytes, quantity, ordering and original creation point retain #200 semantics | view differs from known same-point model or stored bytes |

Socket atomicity and point refusal each need their own failing assertion under
their respective faults. A compile failure, missing test, exception, pending
example or test-runner failure is setup failure, never behavioral RED.

## Non-goals and limits

No arbitrary historical reads, new coverage/freshness fields (#201), storage
migration/persistence work (#202), release, preprod/public writes, secrets, or
Singular changes. A consumer compares independent node/indexer points and
reacquires its node view when they disagree. No delivery claim from planning.

S2 is planned but blocked until the epic owner forwards Q-001's scope answer.
If moved out, AC2/AC4/socket docs remain unfulfilled here until explicitly
re-scoped by the authoritative owner; S1 alone does not complete current #210.
