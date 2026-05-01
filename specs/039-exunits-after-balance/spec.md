# Feature Specification: Balance-Aware ExUnits

**Feature Branch**: `039-exunits-after-balance`  
**Created**: 2026-05-01  
**Status**: Draft  
**Input**: GitHub issue #112: `TxBuild.build patches ExUnits before balance, so post-balance change-output blows the per-script budget`

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Build Covers Final TxInfo Cost (Priority: P1)

As an off-chain transaction author using `TxBuild.build`, I need the
patched redeemer execution units to cover the transaction body that is
submitted, not an earlier unbalanced draft, so validators that inspect
outputs, inputs, mint, or reference inputs do not fail at submission
with a small post-balance budget deficit.

**Why this priority**: This is the reported production failure path.
`build` is the primary transaction assembly API and downstream users
already follow the documented workflow.

**Independent Test**: A unit test can provide a deterministic evaluator
whose returned CPU depends on the number of outputs visible in the
transaction. The resulting built transaction must contain redeemer
ExUnits equal to the balanced transaction's output count cost.

**Acceptance Scenarios**:

1. **Given** a transaction program with one script spend and one paid
   output, **When** balancing adds a change output, **Then** the final
   redeemer ExUnits reflect the two-output balanced transaction.
2. **Given** a transaction program whose fee and change converge across
   multiple build iterations, **When** the final transaction is returned,
   **Then** the final redeemer ExUnits match a final evaluation of that
   returned transaction.

---

### User Story 2 - evaluateAndBalance Covers Final TxInfo Cost (Priority: P1)

As a caller that already has an unbalanced transaction, I need
`evaluateAndBalance` to produce the same balance-aware ExUnits guarantee
as `build`, so both documented transaction workflows are safe for
validators that traverse transaction fields.

**Why this priority**: The issue identifies `evaluateAndBalance` as
having the same eval-patch-balance ordering bug.

**Independent Test**: A unit test can call `evaluateAndBalance` with a
provider whose evaluator returns CPU proportional to output count. The
final redeemer ExUnits must equal the balanced transaction's output
count cost.

**Acceptance Scenarios**:

1. **Given** an unbalanced transaction with a script redeemer and one
   output, **When** `evaluateAndBalance` adds change, **Then** the final
   redeemer ExUnits reflect the balanced transaction.
2. **Given** script evaluation fails at any evaluation point, **When**
   `evaluateAndBalance` runs, **Then** the failure is surfaced instead
   of returning an under-budgeted transaction.

### Edge Cases

- Transactions without redeemers must continue to balance without
  forcing unnecessary script-evaluation assumptions.
- Evaluation failures during the initial or balance-aware evaluation
  must remain visible as errors.
- Existing fee convergence and fee-oscillation handling in `build` must
  continue to terminate and preserve `Peek` semantics.
- Existing explicit ExUnits margin configuration must remain applied to
  the evaluated values that are finally patched.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: `build` MUST return transactions whose patched redeemer
  ExUnits are based on evaluation of the balanced transaction body that
  will be submitted.
- **FR-002**: `evaluateAndBalance` MUST return transactions whose
  patched redeemer ExUnits are based on evaluation of the balanced
  transaction body that will be submitted.
- **FR-003**: If balance-aware evaluation changes any redeemer ExUnits,
  the transaction MUST be rebalanced so fees and change are consistent
  with the patched units.
- **FR-004**: The convergence process MUST stop only when both the fee
  and patched ExUnits are stable for the final balanced transaction.
- **FR-005**: Existing script evaluation failures MUST continue to be
  reported to callers rather than hidden by balancing retries.
- **FR-006**: The existing ExUnits margin option MUST still be applied
  to ExUnits before the script integrity hash is recomputed.

### Key Entities

- **Balanced Transaction**: The transaction body after fee calculation,
  fee inputs, and change output have been applied.
- **Evaluation Result**: The per-redeemer ExUnits or script failure
  returned by the evaluator for a specific transaction body.
- **Patched Redeemers**: Redeemers in the transaction witness set after
  replacing placeholder or prior ExUnits with evaluated ExUnits.
- **Convergence State**: The observed fee and ExUnits values used to
  decide whether another build/balance iteration is required.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A regression test for `build` fails on the old
  eval-patch-balance ordering and passes when ExUnits are patched from
  the balanced transaction evaluation.
- **SC-002**: A regression test for `evaluateAndBalance` fails on the
  old eval-patch-balance ordering and passes when ExUnits are patched
  from the balanced transaction evaluation.
- **SC-003**: Existing unit and e2e tests continue to pass.
- **SC-004**: The CI gate
  `nix build --quiet .#checks.x86_64-linux.build .#checks.x86_64-linux.e2e .#checks.x86_64-linux.lint`
  passes.

## Assumptions

- The evaluator is deterministic for a fixed transaction body and
  protocol-parameter set.
- Balancing may add fee inputs and a change output, and validators can
  observe those fields through TxInfo.
- The implementation can reuse the existing evaluator and balancer
  interfaces without introducing a new public API.
- Unit tests may use deterministic in-process evaluators because the
  behavior under test is the library's ordering and convergence logic,
  not node communication.
