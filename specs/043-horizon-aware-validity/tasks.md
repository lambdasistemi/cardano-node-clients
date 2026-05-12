# Tasks — Horizon-Aware Validity Helper

Spec: [spec.md](spec.md) · Plan: [plan.md](plan.md) · Issue: [#133](https://github.com/lambdasistemi/cardano-node-clients/issues/133).

## S1 — Pure horizon math + unit fixtures *(one reviewed commit)*

| Task | Type | Folds with | Output |
|---|---|---|---|
| T1.1 | RED | T1.2 | `test/Cardano/Node/Client/ValiditySpec.hs` — three hand-built `Summary` fixtures wrapped with `mkInterpreter`: `midEpochInterp` (last era bounded; tip far from end), `lateEpochInterp` (last era bounded; tip near end), `unboundedInterp` (last era `EraUnbounded`). |
| T1.2 | RED | T1.3 | Unit assertions: 9 cases (3 fixtures × 3 `ValidityChoice` cases) keyed to spec acceptance scenarios. Each assertion compares `Either HorizonError SlotNo` against a hand-computed expected value. |
| T1.3 | GREEN | T1.1, T1.2 | `lib/Cardano/Node/Client/Validity.hs` exporting `HorizonError (..)`, `ValidityChoice (..)`, `selectUpperBound`. Internal binary search uses `interpretQuery interp (slotToWallclock s)` as the in-horizon predicate. Wired into the cabal file's `library` exposed-modules. |
| T1.4 | chore | — | Test suite stanza exposed — add `Cardano.Node.Client.ValiditySpec` to the `unit-tests` test suite's `other-modules` (or whatever the existing pattern is — check `unit/Spec.hs` for hspec-discover usage). |

**Reviewed commit message** (working title for solo author):

```
feat: Cardano.Node.Client.Validity — horizon-aware upper-bound math
```

**Folding into one commit**: T1.1–T1.4 land in a single `git commit` after running unit tests RED→GREEN locally. No intermediate commits.

## S2 — Provider extension + devnet e2e *(one reviewed commit)*

| Task | Type | Folds with | Output |
|---|---|---|---|
| T2.1 | RED | T2.2, T2.3 | `e2e-test/Cardano/Node/Client/E2E/Devnet/HorizonSpec.hs`: spin up devnet via the existing `withCardanoNode` harness, connect a Provider, call `queryUpperBoundSlot AutoLongest`, assert the returned slot ≥ tip and that `posixMsToSlot` round-trip on the corresponding time succeeds (no `PastHorizon`). |
| T2.2 | GREEN | T2.1, T2.3 | Extend `Cardano.Node.Client.Provider`: add `queryUpperBoundSlot :: ValidityChoice -> m (Either HorizonError SlotNo)`. |
| T2.3 | GREEN | T2.1, T2.2 | Wire `N2C.Provider`: implement `queryUpperBoundSlot` via `BlockQuery (QueryHardFork GetInterpreter)` + the existing tip query, then delegate to `Validity.selectUpperBound`. Add to the e2e-tests cabal file. |

**Reviewed commit message**:

```
feat: Provider.queryUpperBoundSlot for horizon-aware validity
```

**Folding**: T2.1–T2.3 land as one commit. The e2e test fails to compile until T2.2/T2.3 ship.

## S3 — Documentation *(one reviewed commit, non-behavioral)*

| Task | Type | Folds with | Output |
|---|---|---|---|
| T3.1 | docs | T3.2 | `docs/horizon-aware-validity.md`: explains epochs, eras, safe zone, and the three `ValidityChoice` modes with a worked example. |
| T3.2 | docs | T3.1 | `mkdocs.yml` + `docs/index.md`: link the new page. |

**Reviewed commit message**:

```
docs: horizon-aware validity helper
```

## RED/GREEN folding summary (pr skill compliance)

Every behavior-changing slice (S1, S2) contains its RED proof and GREEN implementation in the same commit. S3 is docs-only and explicitly marked non-behavioral. No fixup commits planned; review-fix iterations amend the affected slice in place.
