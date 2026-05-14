# Feature Specification: Tx Diff Named Collapse Views

**Feature Branch**: `feat/tx-diff-named-yaml-collapse-views-for-list-diffs`  
**Created**: 2026-05-14  
**Status**: Draft  
**Input**: GitHub issue #142 and user discussion on collapsing repeated list
diffs by named semantic overlays.

## User Scenarios & Testing

### User Story 1 - Collapse Repeated List Diffs (Priority: P1)

A tx-diff user can provide a YAML rule named `swapOrders` for
`body.outputs` so repeated output-item diffs are shown once as a named view,
with the output index dimension moved down to the changed leaves.

**Why this priority**: This is the readability problem observed in the swap
transaction: every output repeats `coin` and the same nested datum paths.

**Independent Test**: Diff two open values with an `outputs` list whose items
share `coin` and nested datum-field changes. Render with a `swapOrders` rule
and verify the tree shows `outputs.swapOrders.coin` and
`outputs.swapOrders.datum...`, with indexed leaf lists.

**Acceptance Scenarios**:

1. **Given** a list diff with items `0`, `1`, and `2` all containing `coin`
   and `datum.fields.4.fields.0.2`, **When** the `swapOrders` rule requires
   those paths, **Then** the named view contains those paths once and lists
   indexed A/B changes under each leaf.
2. **Given** two items have the same A/B leaf change and one item differs,
   **When** the named view is rendered, **Then** equal leaf changes are grouped
   by index ranges without arithmetic aggregation.

### User Story 2 - Keep Rule Overlays Independent (Priority: P2)

A tx-diff user can define multiple named rules at the same list path, and the
same list item may appear in more than one rule when it matches both.

**Why this priority**: The user described groupings as semantic views, not
partitions. Rules must not steal matches from each other.

**Independent Test**: Render a list with `swapOrders` requiring `coin` plus a
datum path and `coinChanges` requiring only `coin`. Verify index `0` appears
in both named views.

**Acceptance Scenarios**:

1. **Given** intersecting rules at `body.outputs`, **When** an item matches
   both rules, **Then** both named views include that item.
2. **Given** raw rendering is enabled, **When** named views are rendered,
   **Then** the original per-index diff remains visible under `raw`.

### User Story 3 - Hide Raw View When Requested (Priority: P3)

A tx-diff user can choose to hide the raw per-index list rendering when named
views are enough.

**Why this priority**: The raw view is useful for verification, but users need
a compact mode for large repeated lists.

**Independent Test**: Render the same list with `views.raw: hide` and verify
the named view remains while the `raw` section is absent.

**Acceptance Scenarios**:

1. **Given** `views.raw: hide`, **When** a collapse rule applies to a list,
   **Then** that list renders only named views.
2. **Given** no rule applies to a list, **When** raw is hidden, **Then** the
   list still renders normally so unrelated diffs are not lost.
3. **Given** a rule represents only some diffs inside a list, **When** raw is
   hidden, **Then** unrepresented list diffs remain visible under their
   original numeric indexes so the renderer does not lose actionable
   differences or invent an extra semantic bucket.

### Edge Cases

- A rule whose required paths match no item renders no named view.
- A rule can require nested numeric path segments such as
  `datum.fields.4.fields.0.2`.
- Rules do not invent semantic names inside datum paths; they only name the
  view itself.
- Inserted or deleted list items are not collapsed in the first slice; raw or
  original numeric-index rendering remains the source of truth for them.
- Hiding the raw view never hides diffs that are not represented by at least
  one named collapse view; those diffs render under their original numeric
  indexes.

## Requirements

### Functional Requirements

- **FR-001**: The CLI MUST accept one YAML collapse-rules file.
- **FR-002**: A collapse rule MUST have a name, an absolute list path, and one
  or more required relative diff paths.
- **FR-003**: Collapse rules MUST be independent overlays; intersecting rules
  may include the same list item.
- **FR-004**: For a matching rule, the renderer MUST transpose
  `List<Indexed DiffTree>` into `DiffTree<List<Indexed DiffLeaf>>`.
- **FR-005**: Equal A/B diff leaves inside a named view MUST be grouped by
  exact equality and rendered with compact index ranges.
- **FR-006**: The YAML config MUST support `views.raw: show|hide`.
- **FR-007**: Without a collapse-rules file, existing tree and path render
  behavior MUST remain unchanged.
- **FR-008**: This feature MUST NOT perform semigroup aggregation, arithmetic
  folding, sums, or computed deltas.
- **FR-009**: With `views.raw: hide`, the renderer MUST still show changed
  list-item leaves, insertions, and deletions under their original numeric
  indexes when no named collapse view represents them.
- **FR-010**: Tree-mode changed leaves MUST render A and B on separate child
  lines with the values right-aligned against each other.

### Key Entities

- **Collapse Rules File**: YAML input describing raw-view settings and named
  collapse rules.
- **Collapse Rule**: A named semantic overlay at one list path, selecting list
  items by required relative diff paths.
- **Collapsed View**: Rendered named tree where the list index dimension is
  attached to changed leaves.

## Success Criteria

### Measurable Outcomes

- **SC-001**: A three-item repeated output diff renders each repeated datum
  path once under the named view, not once per output item.
- **SC-002**: An item matching two rules appears in both rendered named views.
- **SC-003**: Running tx-diff without a collapse-rules file produces byte-for-
  byte identical output for existing unit examples.
- **SC-004**: The first implementation adds no arithmetic aggregation behavior.
- **SC-005**: `views.raw: hide` never makes the rendered output report fewer
  underlying differences than the selected named views cover.

## Assumptions

- YAML path syntax is dot-separated text with numeric list indexes represented
  as path segments.
- The first implementation targets human tree output; explicit path rendering
  remains unchanged.
- Raw view defaults to `show`.
