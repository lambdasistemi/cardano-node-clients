# Data Model: tx-diff Render Modes

## RenderShape

Represents the high-level structure of human output.

Fields:

- `tree`: group shared path prefixes and render changed leaves below them.
- `paths`: render changed leaves as standalone full path lines.

Default:

- `tree`.

Validation:

- Values outside the supported set are rejected before transaction inputs are
  read.

## TreeArt

Represents connector and indentation style for tree-shaped output.

Fields:

- `unicode`: readable connector art for Unicode-capable terminals.
- `ascii`: portable connector art for logs and minimal terminals.
- `plain`: optional indentation-only spelling if implementation chooses to
  support it separately from ASCII.

Default:

- `ascii`.

Validation:

- Applies only when `RenderShape` is `tree`.
- Unsupported values are usage errors.

## HumanRenderOptions

User-facing rendering selection.

Fields:

- `renderShape`: selected `RenderShape`.
- `treeArt`: selected `TreeArt` when tree rendering is active.

Relationships:

- Consumed by the library renderer.
- Derived from CLI flags in `tx-diff`.

## RenderedDiffNode

A presentation node derived from an existing `DiffNode`.

Fields:

- `label`: path segment or leaf marker shown on the current line.
- `kind`: branch, changed leaf, only-A leaf, only-B leaf, or same marker.
- `children`: rendered child nodes.
- `valueA` / `valueB`: rendered side values for changed leaves.

Validation:

- Must not contain transaction comparison logic.
- Must not expand equal subtrees that the diff model suppressed.
