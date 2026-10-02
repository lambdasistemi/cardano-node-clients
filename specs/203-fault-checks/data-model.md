# Data model — #203

- DM1 Fault identity: name ∈ {`fault-asset-matching`, `fault-snapshot-binding`};
  guarded behaviour (R1 | R2); named guarding example (hspec path).
- DM2 Outcome: `KILLED` | `SURVIVED` | `SETUP-FAILURE:<reason>`; exactly one per run,
  printed on one line `FAULT-CHECK <name> outcome=<outcome> example=<path>`;
  exit 0 `KILLED`, 2 `SETUP-FAILURE`, 3 `SURVIVED`; exit 1 only from nix when the
  faulted build fails (no outcome line).
- DM3 Setup reasons (non-exhaustive, owner extends): fault-not-applied,
  example-not-run, failed-by-exception. A faulted build failure is nix exit 1, not a
  script reason.
