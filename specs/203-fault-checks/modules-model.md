# Modules model — #203

- M1 Fault seam (test/check-only). Owns the two controlled faults (F-MATCH, F-BIND)
  applied to the asset query's matching decision (`scanAsset`, Indexer.hs) and its
  one-transaction read (`readAssetSnapshot`, Indexer.hs). Depends on production
  source; nothing in production depends on it (INV-5).
- M2 Fault check runner (nix/checks.nix gate). Builds the faulted unit suite, runs the
  named guarding example, classifies the result into the R4 outcome vocabulary.
  Depends on M1 and the `unit-tests` sources.
- M3 CI wiring (`.github/workflows/ci.yml`). One job per fault check, `needs:
  build-gate`; build-gate builds the check derivations.
- Guarding tests stay in `unit-tests`; any strengthening lives there.
