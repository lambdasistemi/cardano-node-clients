# Data model v1 — #210

- D210-1 `ReadQuery`: `AddressQuery Address` or
  `AssetQuery PolicyId AssetName`. Reuse validated existing key types.
- D210-2 `ReadResult`: `AddressResult [(TxIn, TxOut)]` or
  `AssetResult [AssetMatch]`. Answers correspond one-for-one to queries in
  input order, including duplicates. Outputs remain ascending by `TxIn`;
  bytes and asset provenance preserve #200 semantics.
- D210-3 `IndexedView`: `ivPoint :: (SlotNo, BlockHash)` and
  `ivResults :: NonEmpty ReadResult`. Point and complete results are from the
  same transaction. Query/result length and constructor alignment are exact.
- D210-4 failures: reuse `AssetQueryUnavailable` without changing constructors
  or existing meanings. Any failed availability/integrity requirement refuses
  the complete view, including an address-only view.
- D210-5 S2 requested point P: nonnegative slot and a 32-byte block hash.
  Equality is exact; the same slot with another hash is a mismatch.
- D210-6 S2 request: P, a nonempty ordered query list, and a bounded timeout.
  Results carry one point and ordered typed answers. Point refusals carry P,
  the actual snapshot point, and a reason (behind at expiry, ahead, fork).
  No-point state uses D210-4 unavailability and never a fabricated point.

D210-5/6 are planned only. Exact JSON field spelling, timeout default/cap and
malformed-request refusal will be frozen in an S2 wire contract after Q-001
is answered and before its commit owner launches. Existing request bytes and
legacy parser precedence are preserved. No stored data format changes.
