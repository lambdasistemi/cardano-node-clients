# Data Model: Balance-Aware ExUnits

## Entities

### Evaluation Result

- Key: Plutus purpose.
- Value: either script failure or evaluated ExUnits.
- Constraint: only successful ExUnits are patched into matching
  redeemers.

### Redeemer ExUnits Snapshot

- Representation: map from Plutus purpose to ExUnits.
- Used to compare whether a later balance-aware evaluation changed any
  redeemer cost.

### Balanced Transaction Candidate

- Transaction after redeemer patching, script-integrity recomputation,
  fee calculation, fee-input selection, and change-output creation.
- Constraint: the final returned candidate must have redeemer ExUnits
  equal to the successful evaluation result for that same candidate
  after applying the configured margin.

### Convergence State

- Existing fee state: previous fee, seen fees, maximum fee, and retry
  count.
- New ExUnits state: redeemer ExUnits snapshot from the latest
  balance-aware evaluation.
- Stable when final fee and final ExUnits match the latest balanced
  candidate, and existing `Peek` checks have converged.

## Relationships

- An Evaluation Result patches a transaction's redeemers.
- Patched redeemers determine script integrity hash and minimum fee.
- Balancing can change the transaction body observed by the next
  Evaluation Result.
- Convergence compares the patched Balanced Transaction Candidate
  against the next Evaluation Result.
