# Tasks — #207

## S1 build coverage recorded and served

- [x] T001 DM12 codec and record decision in one transaction, both backends, degraded → unrecorded (P1, P2, H0–H2, V1, V7, V8, V10)
- [x] T002 Follower claims once per bracket, refuses before chain-sync, exposes outcome (P3, H3–H4, V2–V4)
- [x] T003 Disclosure `unknown` values, `coverage_unknown` limit, `storeCoverage`; server encoding (P4, P5, H5–H6, V5, V6)
- [x] T004 Daemon disclosure from the store outcome; `followerCoverage` deleted (P6, V5, V9)
- [x] T005 Specs: reopen same / changed start / changed filter on RocksDB and in-memory; legacy store unknown; corrupt record; limits matrix; byte stability (V1–V10)
- [x] T006 `docs/usage/utxo-indexer.md` Coverage section and limits table (R7)
