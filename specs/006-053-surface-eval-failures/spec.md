# Feature Specification: Surface terminal eval failures

**Feature Branch**: `006-053-surface-eval-failures`
**Created**: 2026-04-14
**Status**: Draft
**Input**: Issue #53

## User Scenarios & Testing

### User Story 1 - Terminal script failure returns error (Priority: P1)

A developer uses the TxBuild DSL with a script that has a
logic bug (e.g., wrong redeemer, bad datum encoding). The
`build` function should return `Left (EvalFailure purpose msg)`
after detecting the failure is stable, not retry indefinitely.

**Why this priority**: Without this, any script bug causes
a hang instead of an actionable error message.

**Independent Test**: Mock evaluator that always fails for
a specific purpose → `build` returns `EvalFailure`.

**Acceptance Scenarios**:

1. **Given** a program with a script spend whose evaluator
   always returns `Left "logic error"` for that purpose,
   **When** `build` is called,
   **Then** it returns `Left (EvalFailure purpose "logic error")`.

2. **Given** a program with two script spends where one
   always fails and one succeeds,
   **When** `build` is called,
   **Then** it returns `Left (EvalFailure failingPurpose msg)`.

---

### User Story 2 - Fee-related eval failures still retry (Priority: P1)

A developer uses the TxBuild DSL with a conservation
validator. On the first iteration (fee=0), the script
fails because the fee hasn't been estimated yet. The
`build` function should retry with an estimated fee and
eventually converge.

**Why this priority**: This is the existing behavior that
must be preserved — fee-bootstrapping depends on retry.

**Independent Test**: Mock evaluator that fails when fee=0
but succeeds when fee>0 → `build` converges.

**Acceptance Scenarios**:

1. **Given** a program whose evaluator fails at fee=0 but
   succeeds at fee>0,
   **When** `build` is called,
   **Then** it returns `Right tx` with a valid fee.

---

### Edge Cases

- What if eval fails on iteration 1 (fee=0) but succeeds
  on iteration 2, then fails again on iteration 3 with a
  different error? The second failure is stable → return
  `EvalFailure`.
- What if all scripts fail? Return the first failure.
- What if the same script fails with different messages
  across iterations? The message content may vary — detect
  stability by purpose, not by message string.

## Requirements

### Functional Requirements

- **FR-001**: `build` MUST return `Left (EvalFailure purpose msg)`
  when a script evaluation failure is detected as stable
  (not fee-related).
- **FR-002**: `build` MUST retry on eval failure when
  `prevFee == 0` (first iteration, fee bootstrapping).
- **FR-003**: `build` MUST NOT retry indefinitely — if eval
  fails and the fee has already been established (prevFee > 0),
  use the previous ExUnits fallback or surface the error.
- **FR-004**: The existing `BuildError` type's `EvalFailure`
  constructor MUST be used (no new error types needed).

## Success Criteria

### Measurable Outcomes

- **SC-001**: A mock evaluator that always fails causes
  `build` to return in bounded time (not hang).
- **SC-002**: Existing unit tests (67) and E2E tests (10)
  continue to pass.
- **SC-003**: New regression test covers the terminal
  failure case.

## Assumptions

- The evaluator function provided to `build` is deterministic
  for the same transaction — same tx in, same result out.
- Fee-related failures happen on early iterations (fee=0 or
  fee too low). Once a successful eval has occurred, subsequent
  failures for the same purpose are terminal.
