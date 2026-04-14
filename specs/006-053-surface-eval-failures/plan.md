# Implementation Plan: Surface terminal eval failures

## Research

The eval-fail branch in `step` has two paths:

1. `estFee >= prevFee` → retry with higher fee (line 979)
2. `prevFee > 0` → reuse prevTx ExUnits (line 990)

Path 1 loops forever when eval always fails: estFee stays
constant, prevFee catches up, and the condition remains
true on every retry.

Path 2 is only reached when estFee < prevFee, which means
a successful balance already happened. This path correctly
handles the "eval fails after a prior success" case.

The gap: there is no exit for "eval always fails, fee can't
help." The retry counter is implicit in `seenFees` but only
checked on the success path.

## Design

Add an eval retry counter to `step`. When eval fails and
we've already retried once at the same or higher fee without
any successful eval in between, surface `EvalFailure`.

Specifically:
- Add an `evalRetries :: Int` parameter to `step`
- On eval failure: if `evalRetries > 0` AND the fee
  hasn't changed (estFee == prevFee or estFee < prevFee
  with no prior success), return `EvalFailure`
- On eval success: reset `evalRetries` to 0
- Initial call: `evalRetries = 0`

This distinguishes:
- First failure at fee=0 → retry (evalRetries 0→1)
- Second failure at similar fee → terminal (evalRetries=1)
- Failure after a prior success → use prevTx ExUnits
  (existing path 2, unchanged)

## Slices

### Slice 1: Add evalRetries counter and terminal exit

- Add `evalRetries` parameter to `step`
- On eval failure path 1 (estFee >= prevFee):
  if evalRetries >= 1, return `Left (EvalFailure p msg)`
  using the first failure from the list
- On eval success: pass evalRetries=0 to recursive calls
- On eval failure retry: pass evalRetries+1

### Slice 2: Regression test

- Unit test with mock evaluator that always fails
  → verify `build` returns `EvalFailure`
- Unit test with mock evaluator that fails at fee=0
  but succeeds at fee>0 → verify `build` converges
