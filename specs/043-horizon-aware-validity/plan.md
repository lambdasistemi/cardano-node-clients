# Plan — Horizon-Aware Validity Helper

**Spec**: [spec.md](spec.md) — User Stories 1–3.
**Issue**: [#133](https://github.com/lambdasistemi/cardano-node-clients/issues/133).
**Branch**: `feat/133-horizon-aware-validity`.

## Design Decisions

### D1. Pure horizon math drives `Interpreter` through its public `interpretQuery` API.

The `Interpreter xs` from `Ouroboros.Consensus.HardFork.History.Qry` is the only handle the node hands us via `GetInterpreter`. Its inner `Summary` is documented as *internal*: there is no public accessor, and the only ways to get it out are `Serialise` round-trip or `unsafeCoerce`. We use neither.

Instead the pure function drives the `Interpreter` through `interpretQuery interp (slotToWallclock s)`. The Qry returns `Right _` iff `s` is currently translatable. To find the horizon we **binary-search** the range `[tip, tip + searchUpper]` using this probe as the predicate. Search converges in ~20 probes for any sensible `searchUpper` (≤ 1 year of slots) and never touches `Summary`.

For unit tests we build `Summary` values by hand using the publicly-exported `Summary (..)` constructor plus `EraSummary`/`EraEnd`/`EraParams`, then wrap with `mkInterpreter :: Summary xs -> Interpreter xs`. The hand-built `Summary` is the only well-supported way to fixture an `Interpreter` and is explicitly documented as such (see `Summary.summaryWithExactly`).

**Trade-off considered:** Walking the `Summary` directly would give us era-boundary info "for free" (we could classify the horizon as "era end known" vs "safe zone only"). Binary-search probes don't. We accept this loss because the classification is advisory only — callers don't act on it — and not depending on `Summary` internals is worth more than a richer error.

### D2. `ValidityChoice` is closed sum, not an extensible config.

Three constructors (`AutoLongest`, `MaxHours`, `ExactlyHours`) cover the requirement and admit `case` exhaustiveness checks. A polymorphic "policy" type would over-engineer; if we need a fourth case (e.g. `Slot SlotNo` for explicit slot), it is a one-line add.

### D3. `HorizonError` carries facts, not a rendered message.

Caller renders the diagnostic. `HorizonError` records the requested slot, the horizon slot, the tip slot, and the requested hours. We do not include POSIX times — the caller already has `posixMsToSlot` and friends to compute time from slot if needed. Era-end and safe-zone are intentionally absent (see D1).

### D4. Gate is `just ci` + a new e2e case.

`just ci` already runs `build → e2e → unit → cabal-fmt → fourmolu → hlint`. The new e2e case lives in `e2e-test/Cardano/Node/Client/E2E/Devnet/HorizonSpec.hs` and exercises the boundary smoke for User Story 1. No new gate script needed; `llm/reviews/<PR>/gate.sh` will just call `nix develop -c just ci`.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| `Summary`/`EraSummary` types differ across consensus versions; copy-paste from upstream sources is fragile. | Slice 1 imports only from `Ouroboros.Consensus.HardFork.History.Summary` and `Cardano.Slotting.Slot`; we don't redefine ledger types. Failure to compile fails the gate immediately. |
| `EraHistory` is parameterised over the era stack; the right phantom type is non-obvious. | Slice 1 fixes the type to `EraHistory (CardanoEras StandardCrypto)` (same shape used by the existing Provider). |
| Unit test fixtures require a non-trivial `Summary` value. | Slice 1 builds `Summary` from a literal `NonEmpty EraSummary` constructed in code. Each fixture is 30–60 lines, plain record syntax. No serialization needed. |
| `safeZone` is `SafeZone` data type with `StandardSafeZone Word64` and `UnsafeIndefiniteSafeZone` cases; choosing the wrong one in fixtures yields silent off-by-N. | Slice 1 fixtures use exclusively `StandardSafeZone n` where `n` matches mainnet (`129600`) and the synthetic unbounded case uses `UnsafeIndefiniteSafeZone`. We make this an explicit field in test names so each fixture self-documents. |
| Devnet may not advance into a safe zone within test runtime. | E2E test asserts only "auto slot is translatable" (a horizon-respecting invariant) — it does not assert "auto slot equals end-of-epoch + safezone". The boundary-case math is in unit tests. |

## Slice Plan (vertical commits)

Each slice is a single bisect-safe reviewed commit including RED tests and GREEN implementation.

### S1 — Pure horizon math + unit fixtures

- **RED**: unit tests in `test/Cardano/Node/Client/ValiditySpec.hs` covering three fixtures (mid-epoch, safe-zone, unbounded) and three `ValidityChoice` cases.
- **GREEN**: new module `lib/Cardano/Node/Client/Validity.hs` with `HorizonSlot`, `HorizonBoundary`, `HorizonError`, `ValidityChoice`, and `maxTranslatableUpperBound`.
- **Bisect-safe**: yes — exposes a pure API with passing tests.
- **TDD/DDD proof**: 3 fixtures × 3 choices = 9 unit assertions, named per Given/When/Then in spec.

### S2 — Provider extension

- **RED**: a new e2e test `e2e-test/Cardano/Node/Client/E2E/Devnet/HorizonSpec.hs` that calls the (not-yet-existing) `queryUpperBoundSlot`. Will fail to compile until S2's GREEN ships.
- **GREEN**: extend `Provider` record and `N2C.Provider` with `queryUpperBoundSlot`, delegating to `Validity.selectUpperBound`. Uses the existing `GetInterpreter` + tip queries.
- **Bisect-safe**: yes — the e2e is the boundary smoke; if S2 lands without S1 the import would fail to resolve.
- **TDD/DDD proof**: one e2e assertion validating User Story 1 acceptance scenario 3.

### S3 — Documentation

- New `docs/horizon-aware-validity.md`, linked from `docs/index.md` and `mkdocs.yml`. Worked example + safe-zone explanation. No code change.
- **Bisect-safe**: docs-only; no risk to gate.
- **Not a behavior change** — exempt from TDD per pr skill ("Mark non-code tasks as docs ...").

## Out of Scope (carried from spec)

- `amaru-treasury-tx` integration.
- Lower validity bound.
- Provider-side automatic retry on overrun.

## Gate

`llm/reviews/local-feat-133-horizon-aware-validity/gate.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
nix develop --quiet -c just ci
```

The boundary smoke (live devnet) is the new e2e case from S2.
