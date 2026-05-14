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

## Decision: `tree-render-text` is not usable with this GHC

`tree-render-text` exposes `renderTree` / `renderForest` and render options,
including traced Unicode and traced ASCII options.

**Rationale**: It directly matches the requirement for selectable tree art,
but the latest available package declares `base ^>=4.12.0.0`. This repository
builds with GHC 9.12.3 and `base-4.21`, so using it would require an
`allow-newer` workaround or a vendored patch. That is not acceptable for this
small rendering feature.

**Alternatives considered**:

- `tree-view`: Hackage describes it as rendering trees as foldable HTML and
  Unicode art, with a concise Unicode example. It is attractive for Unicode
  output, but it does not obviously cover ASCII/plain logs.
- `Data.Tree.drawTree`: lower dependency cost, weaker art control.

Sources:

- https://hackage.haskell.org/package/tree-render-text/docs/Data-Tree-Render-Text.html
- https://hackage.haskell.org/package/tree-view

## Decision: Use `containers` for ASCII and `tree-view` for Unicode

Use `Data.Tree.drawForest` from the existing `containers` dependency for the
default ASCII tree. Add `tree-view` only for Unicode tree art. Keep the
transaction diff traversal and displayed leaf formatting inside
`Cardano.Node.Client.TxDiff`; only delegate connector layout to these tree
renderers.

**Rationale**: `containers` is already present and gives a portable
non-Unicode tree. `tree-view` is BSD3, declares `base < 5`, and renders
Unicode tree art. This satisfies both accepted art modes without adding a
stale package or a second diff engine.

**Verification**:

- `nix develop --quiet -c cabal list tree-render-text --simple-output`
  lists `tree-render-text 0.4.0.0`.
- `nix develop --quiet -c cabal get tree-render-text-0.4.0.0`
  downloads the source package and shows the incompatible `base ^>=4.12.0.0`
  bound.
- `nix develop --quiet -c cabal get tree-view`
  downloads `tree-view-0.5.1`, whose cabal file declares `BSD3` and
  `base < 5`.

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

## Closed Implementation Check

`tree-render-text` is visible at the pinned index state but is incompatible
with this GHC. Implementation will add `tree-view` as the narrow Unicode
rendering dependency and keep ASCII rendering on `containers`.
