# Data Model: Pre-submit chain-tip UTxO probe

**Branch**: `038-tx-gen-presubmit-probe`
**Date**: 2026-05-01

## Entities

### Probe outcome

A per-submit-attempt boolean derived from one LSQ query.

```haskell
-- Conceptual; not a new type — represented inline as Bool.
type AllInputsUnspent = Bool
```

`True`  ⇒ every input of the about-to-be-submitted tx is present in the
relay's tip UTxO set; submit may proceed.
`False` ⇒ at least one input is missing (already spent or rolled back); the
arm short-circuits.

### Provider's new query primitive

The reusable shape behind the boolean wrapper.

```haskell
queryUTxOByTxIn :: Set TxIn -> m (Map TxIn (TxOut ConwayEra))
```

- **Input**: the set of inputs the daemon plans to spend in the next submit.
  Refill: a singleton `{faucetTxIn}`. Transact: K inputs `{S1..Sk}`.
- **Output**: a `Map` containing only those inputs that are still unspent at
  the relay's current tip. Inputs not in the result are missing (spent or
  rolled past).
- **Round trips**: 1.
- **Wire query**: ouroboros-network LSQ
  `BlockQuery (QueryIfCurrentConway (GetUTxOByTxIn txins))` against the
  provider's `LSQChannel`.

### Probe failure mode

If the LSQ channel is unavailable, `queryUTxOByTxIn` raises `ConnectionLost`
(same exception that the submit primitive raises). The arm's existing
`E.handle ConnectionLost` returns `IndexNotReady`. No new failure constructor
needed.

## Relationships

- The probe is *between* tx construction and the submit primitive call. It
  reads from the same `Provider IO` value that other arm operations already
  thread through.
- Probe inputs ⊆ tx inputs ⊆ inputs the indexer reported as unspent at
  tx-build time. The probe is the *third* check on these inputs (indexer view
  → tx build → tip view).

## State transitions

The probe does not maintain state. It is a pure read against the Provider.
The arm's *response* state — `RefillFail IndexNotReady` vs.
`Submitted txId` — flows from the existing failure-reason machinery in
`Cardano.Node.Client.TxGenerator.Types.FailureReason`. No new constructor.

## Invariants

- I1. The probe MUST run after the freshness gate (`rsIndexFresh`). If the
  freshness gate is False, the arm body never executes, so the probe cannot
  fire spuriously.
- I2. The probe MUST run before `submitTx submitter signed`. If the probe
  returns False, `submitTx` MUST NOT be called.
- I3. On any short-circuit (probe False or `ConnectionLost` from the probe),
  the HD-index counter MUST NOT advance. Inherited from the existing
  short-circuit pattern.
