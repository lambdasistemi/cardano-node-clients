# Data model — #203

- DM1 Fault identity: name ∈ {`fault-asset-matching`, `fault-snapshot-binding`};
  guarded behaviour (R1 | R2); named guarding example (hspec path).
- DM2 Outcome: `KILLED` | `SURVIVED` | `SETUP-FAILURE:<reason>`; exactly one per run,
  printed on one line `FAULT-CHECK <name> outcome=<outcome> example=<path>`;
  exit 0 iff `KILLED`.
- DM3 Setup reasons (non-exhaustive, owner extends): fault-not-applied, build-failed,
  example-not-run, failed-by-exception.
