# Feature Specification: Horizon-Aware Validity Helper

**Feature Branch**: `feat/133-horizon-aware-validity`
**Created**: 2026-05-12
**Status**: Draft
**Issue**: [#133](https://github.com/lambdasistemi/cardano-node-clients/issues/133)
**Input**: User description: "Pure module that exposes the longest plutus-translatable upper-bound slot given the chain's era history, with an optional manual hours override. Belongs in `cardano-node-clients` because nothing in the math is Amaru-specific."

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Build a tx with the longest safe `invalid-hereafter` (Priority: P1)

A tx-build caller asks "give me the longest upper-bound slot I can use right now". The library queries chain state and returns a `SlotNo` guaranteed to survive Plutus context translation; the caller passes it into `TxBuild.upperValidity` without further reasoning.

**Why this priority**: This is the entire motivation for the feature. Without it, every tx-build caller re-implements safe-zone math (poorly) or hard-codes a small fixed window that wastes signing time.

**Independent Test**: Against a live devnet node, calling `queryUpperBoundSlot AutoLongest` returns a slot, and using that slot as `invalid-hereafter` on a simple Plutus-scripted tx that the same node evaluates succeeds (no `TimeTranslationPastHorizon`).

**Acceptance Scenarios**:

1. **Given** a synced node and tip well inside an era (mid-epoch, mainnet), **When** the caller asks for `AutoLongest`, **Then** the returned slot is exactly the era end slot.
2. **Given** a synced node and tip inside the era's safe zone (≤ `safeZone` slots from the era end), **When** the caller asks for `AutoLongest`, **Then** the returned slot is `eraEnd + safeZone` (or the documented equivalent the interpreter can translate).
3. **Given** the slot returned by `AutoLongest`, **When** the caller asks `posixMsToSlot` for the corresponding POSIX time (or evaluates a script with that upper bound), **Then** no `PastHorizon` error occurs.

---

### User Story 2 — Cap auto at a maximum requested hours (Priority: P2)

A caller wants "longest safe, but no more than N hours from tip" — e.g. an internal policy that signing windows must not exceed 24 hours, even when the chain would happily allow more.

**Why this priority**: Pure auto is too aggressive for some operational policies. Without a cap, callers fall back to manual hours and lose the safety check.

**Independent Test**: With a `MaxHours 4` request and a node whose horizon allows 60 h, the returned slot equals `tip + 4*3600`. With a `MaxHours 4` request and a node whose horizon allows only 2 h, the returned slot equals the auto horizon (=2 h).

**Acceptance Scenarios**:

1. **Given** the chain horizon is 60 hours from tip, **When** the caller asks `MaxHours 4`, **Then** the returned slot is `tip + 4 * 3600`.
2. **Given** the chain horizon is 1 hour from tip, **When** the caller asks `MaxHours 4`, **Then** the returned slot is the horizon (≤ `tip + 1 * 3600`).

---

### User Story 3 — Strict manual hours request that fails fast on overrun (Priority: P2)

A caller knows they want exactly N hours and wants the library to refuse rather than silently truncate when the chain horizon is shorter than that.

**Why this priority**: Backwards-compatible behavior for callers that previously hand-computed `tip + N*3600` and are surprised by a quieter clamp.

**Independent Test**: With `ExactlyHours 120` and a horizon of 60 h, the API returns `Left HorizonError` carrying the requested slot, the horizon slot, the era end, and the safe zone size — enough to render a useful diagnostic without re-querying.

**Acceptance Scenarios**:

1. **Given** the horizon is 60 h, **When** the caller asks `ExactlyHours 60`, **Then** the result is `Right slot` with `slot = tip + 60*3600`.
2. **Given** the horizon is 30 h, **When** the caller asks `ExactlyHours 120`, **Then** the result is `Left HorizonError` containing the requested slot (`tip + 120*3600`), the horizon slot, the tip slot, and the requested hours.

---

## Functional Requirements

- **FR-1** Module `Cardano.Node.Client.Validity` exposes a pure `selectUpperBound :: SListI xs => Interpreter xs -> SlotNo {- tip -} -> ValidityChoice -> Either HorizonError SlotNo`. No `IO`, no node access. The `Interpreter` is the same opaque consensus type the Provider already obtains via `GetInterpreter`; we drive it through the public `interpretQuery` API rather than reaching into its internals.
- **FR-2** `HorizonError` carries `requestedSlot`, `horizonSlot`, `tipSlot`, and `requestedHours` — enough for the caller to render a diagnostic like "asked for N h ending at slot R, but horizon is H (tip T)". Era-boundary classification (era end vs safe zone vs unbounded) is **not** modelled in the public type because the `Interpreter`'s `Summary` is documented internal and we don't want to depend on it through Serialise round-trip or `unsafeCoerce`.
- **FR-3** `ValidityChoice` is one of `AutoLongest | MaxHours Word16 | ExactlyHours Word16`. Hours are unsigned `Word16` (max 65535).
- **FR-4** The Provider exposes `queryUpperBoundSlot :: ValidityChoice -> m (Either HorizonError SlotNo)` built on the existing `GetInterpreter` LSQ query plus the existing chain-tip query (`queryTip`). No new wire-level query is required.
- **FR-5** Pure horizon math is covered by unit tests over **three** hand-built `Summary` fixtures (mid-epoch with bounded last era, late-in-era with bounded last era, unbounded last era via `neverForksSummary`). Each fixture is exposed to the pure function as an `Interpreter` via `mkInterpreter`.
- **FR-6** A devnet E2E test asserts that `queryUpperBoundSlot AutoLongest` produces a slot the node can translate forward (the slot is fed back through `posixMsToSlot`-equivalent round-trip via `slotToWallclock` and produces a `Right`).
- **FR-7** `docs/` gains a short page explaining the three choices and the safe-zone mechanic with a worked example.

## Out of Scope

- Wiring `amaru-treasury-tx` wizards to use this module — that ships separately on the `amaru-treasury-tx` repo (tracked as a follow-up; PR #88 already raised the manual cap to 168 h).
- Lower validity bound (`invalid-before`) handling — current API only addresses upper bound.
- Per-era recovery (e.g. degrading from `ExactlyHours` to `MaxHours` on overrun) — the caller decides.
- Sub-slot precision — POSIX-to-slot rounding follows existing Provider conventions.

## Success Criteria

- `just ci` passes (build, e2e, unit, format, hlint).
- E2E test for User Story 1 runs against the existing devnet harness.
- Unit suite covers User Stories 2 and 3 boundary cases.
- Module is consumable by an external caller via `Cardano.Node.Client.Validity` import alone.

## Risks & Notes

- **Interpreter mocking.** `Ouroboros.Consensus.HardFork.History.Qry.Interpreter` is not trivially constructable for tests. Strategy: capture a real `Interpreter` from a running devnet node into a binary file fixture, then deserialize per test. (Or: serialize the underlying `Summary` and rebuild.) Spike this on the first unit slice; if construction is too painful, fall back to property tests that drive the math via a thin `EraSummary`-shaped algebraic input and a separate adapter from `Interpreter`.
- **`Word16` vs `Word32` hours.** `Word16` covers up to 7.4 years; sufficient. Picking `Word16` keeps the API distinct from raw slot counts.
- **Naming.** "Horizon" is the chain term; "validity" is the tx-build term. Module is called `Validity` because its public surface is "what slot can I use as `invalid-hereafter`"; `HorizonSlot` is the internal vocabulary that crosses the boundary.
