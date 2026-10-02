# Modules model v1 — #210

| ID | Owner | Changed responsibility | Dependencies |
|---|---|---|---|
| M210-1 | `lib-utxo-indexer/.../Indexer.hs` | additive query/view data and batch read; own snapshot lifetime and availability | existing Cols, Types, KV transactions; no daemon/ledger dependency |
| M210-2 | `lib/.../UTxOIndexer/Server.hs` (S2) | additive point-bound request, validation, bounded wait and typed wire refusals | M210-1; existing wire/disclosure types |
| M210-3 | `test/.../UTxOIndexer/` | independent model, backend parity, concurrency, socket and compatibility proofs | M210-1/M210-2; existing fixtures and fault classifier |
| M210-4 | `test/fault-check-main.hs`, Cabal test registration, `nix/checks.nix`, `nix/faults/`, `.github/workflows/ci.yml` | execute the three controlled faults and normal specs in head CI; exact root dev-shell CI proof | existing fault-runner/check/app pattern |
| M210-5 | `docs/usage/utxo-indexer.md` | public API, wire and point semantics | D210/F210 rows; executed behavior receipts |

Data ownership: `data-model.md`. Public signature ownership:
`functions-model.md`. No new block-indexer abstraction, dependency pin or
storage schema. Any placement/signature challenge versions the mandate before
implementation proceeds. Existing exports retain Haddock/Apache-2.0 headers.
