# Research: Balance-Aware ExUnits

## Findings

- `Cardano.Node.Client.TxBuild.buildWith` assembles a transaction,
  inflates redeemers for evaluation, patches ExUnits from that
  evaluation, then calls `balanceTx`.
- `balanceTx` may add fee inputs and a change output. Those fields are
  visible to Plutus validators through TxInfo, so any validator that
  traverses outputs, inputs, mint, or reference inputs can cost more
  after balancing than it did during pre-balance evaluation.
- `buildWith` already has fee convergence and bisection logic. The
  missing condition is ExUnits stability for the balanced transaction.
- `Cardano.Node.Client.Evaluate.evaluateAndBalance` has the simpler
  eval-patch-balance shape and needs the same post-balance evaluation
  and rebalancing logic.
- `Cardano.Node.Client.Balance.computeScriptIntegrity` and
  `evalBudgetExUnits` are the existing primitives for safe evaluation
  and integrity hash recomputation.

## Decision

Use a balance-aware convergence loop rather than relying on
`boExUnitsMargin`.

## Rationale

Margins hide the specific failure but do not bound all validator shapes.
Evaluating the balanced transaction makes the patched redeemers match
the transaction body that validators actually see.

## Alternatives Considered

- Increase the default ExUnits margin: rejected because validators can
  traverse balance-added fields any number of times.
- Avoid adding change outputs before evaluation: rejected because fee
  and change are part of the submitted transaction and are validator
  visible.
- Add a new public API: rejected because the current APIs should become
  correct without caller changes.

## Test Strategy

Use deterministic evaluators in unit tests. The evaluator returns
`ExUnits mem steps` where `steps` is proportional to the number of
outputs in the transaction it receives. The test then asserts that the
final redeemer ExUnits match the final balanced output count.
