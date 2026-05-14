# Research: tx-diff Render Modes

## Decision: Keep comparison separate from rendering

The existing `DiffNode` is already hierarchical. The renderer should consume
that tree and should not run `tree-diff` or any other comparison algorithm
over transactions again.

**Rationale**: Re-diffing would duplicate logic and could diverge from the
Conway/blueprint-aware comparison model.

**Alternatives considered**:

- `tree-diff`: Hackage describes it as an expression-tree diff package with
  pretty-printing support and generic derivation helpers. It is useful
  context, but it is a diff engine, not just tree art. It also carries a
  GPL-2.0-or-later license, so it is not a casual dependency for this
  Apache-licensed project.
  Source: https://hackage.haskell.org/package/tree-diff

## Decision: Treat `containers` / `Data.Tree` as the baseline option

The project already depends on `containers`. `Data.Tree` provides a rose tree
type plus `drawTree` and `drawForest` for ASCII drawings.

**Rationale**: This satisfies the constitution's minimal-dependency rule and
is enough for a portable ASCII/plain tree if the accepted design does not
require richer Unicode connectors.

**Alternatives considered**:

- Hand-rolled indentation over `DiffNode`: simplest code, but it risks
  exactly the kind of invented tree art the ticket asks us to avoid.
- Adding a rendering package immediately: may be justified, but only if the
  required art modes exceed `Data.Tree`'s capability.

Source: https://hackage-content.haskell.org/package/containers-0.8/docs/Data-Tree.html

## Decision: `tree-render-text` is the strongest dependency candidate

`tree-render-text` exposes `renderTree` / `renderForest` and render options,
including traced Unicode and traced ASCII options.

**Rationale**: It directly matches the requirement for selectable tree art.
It is more targeted than `tree-view` because it documents both Unicode and
ASCII traced render options.

**Alternatives considered**:

- `tree-view`: Hackage describes it as rendering trees as foldable HTML and
  Unicode art, with a concise Unicode example. It is attractive for Unicode
  output, but it does not obviously cover ASCII/plain logs.
- `Data.Tree.drawTree`: lower dependency cost, weaker art control.

Sources:

- https://hackage.haskell.org/package/tree-render-text/docs/Data-Tree-Render-Text.html
- https://hackage.haskell.org/package/tree-view

## Decision: Render shape and tree art are separate concepts

The user-facing model should distinguish:

- render shape: `tree` or `paths`
- tree art: Unicode or ASCII/plain, applicable only when shape is `tree`

**Rationale**: Path output has no tree art. Keeping the concepts separate
prevents invalid combinations from leaking into renderer internals.

**Alternatives considered**:

- One enum with values like `paths`, `tree-unicode`, `tree-ascii`.
  This is compact for CLI parsing but mixes two user choices and makes future
  additions less clear.

## Open Implementation Check

Before coding, verify whether `tree-render-text` is available in the pinned
Nix/Haskell package set used by this repository. If not, either use
`Data.Tree.drawTree` for the first implementation or add the dependency with
explicit Nix/Cabal proof.
