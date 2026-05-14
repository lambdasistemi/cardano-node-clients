# Feature Specification: tx-diff Render Modes

**Feature Branch**: `132-tx-diff-render-modes`  
**Created**: 2026-05-14  
**Status**: Draft  
**Input**: GitHub issue #139: improve `tx-diff` human rendering with tree
hierarchy, path compatibility, and explicit rendering art selection.

## User Scenarios & Testing

### User Story 1 - Read shared hierarchy once (Priority: P1)

A transaction reviewer compares two Conway transactions and sees related
changes grouped under their shared transaction path instead of repeated as
full dotted paths on every line.

**Why this priority**: This is the usability problem. Several meaningful
changes often live under the same output, datum, redeemer, or witness path.
Repeating the full path makes the report longer while hiding the structure
that the user already understands.

**Independent Test**: Compare two values with two changed leaves under one
shared parent. The human output shows the parent once and both changed leaves
below it.

**Acceptance Scenarios**:

1. **Given** two transactions with multiple changes under the same output,
   **When** the default human renderer is used, **Then** the output path is
   shown once and the changed fields appear as children.
2. **Given** a datum decoded with a matching blueprint, **When** two fields
   inside the decoded datum change, **Then** the datum path is shown once and
   the decoded field names appear as children.
3. **Given** two unrelated changed paths, **When** the tree renderer is used,
   **Then** each path appears under its own branch and no fake shared parent
   is introduced.

---

### User Story 2 - Keep grep-friendly path output (Priority: P2)

A script author or reviewer who prefers the previous flat format can request
path-line output explicitly.

**Why this priority**: The first release exposed flat path lines. Even if tree
mode becomes the better default for humans, path lines remain useful for
copying, searching, and simple text processing.

**Independent Test**: Run the renderer with the path-line selection. The
output uses full paths for changed leaves and does not emit hierarchy-only
parent lines.

**Acceptance Scenarios**:

1. **Given** a transaction difference at `body.fee`, **When** path-line mode
   is selected, **Then** the output contains the full path on the changed
   line.
2. **Given** sibling changes under one parent, **When** path-line mode is
   selected, **Then** each changed leaf line remains independently readable
   without relying on indentation context.

---

### User Story 3 - Select terminal-safe tree art (Priority: P3)

An operator chooses tree art that fits the output medium: readable Unicode
for terminals that support it, or ASCII/plain indentation for CI logs,
markdown, and terminals with uncertain glyph support.

**Why this priority**: Tree hierarchy is useful only if it renders reliably.
Unicode box drawing is readable in good terminals, but release logs and
minimal environments need a safe fallback.

**Independent Test**: Render the same tree with each supported art selection.
The structural grouping is the same, while connector characters match the
selected art.

**Acceptance Scenarios**:

1. **Given** a Unicode-capable terminal, **When** Unicode tree art is
   selected, **Then** branch connectors are visually clear and aligned.
2. **Given** a plain log environment, **When** ASCII/plain art is selected,
   **Then** the output contains only ASCII characters while preserving the
   same hierarchy.
3. **Given** an unsupported art value, **When** the CLI is invoked, **Then**
   it rejects the value with usage guidance and does not attempt a diff.

### Edge Cases

- A single changed root value still renders as one changed value, not an
  empty tree.
- Only-side object keys and array tail entries must be located under the same
  hierarchy rules as changed paired leaves.
- Equal subtrees must remain suppressed; tree mode must not expand equal
  branches just to make the tree look complete.
- Keys or labels containing dots must not become ambiguous with dotted path
  separators in path-line mode.
- Output copied into markdown or CI logs must remain comprehensible without
  terminal colors.
- Unknown or unsupported render options must fail before reading transaction
  inputs.

## Requirements

### Functional Requirements

- **FR-001**: The system MUST support a human tree rendering mode that groups
  shared path prefixes and renders changed leaves under those prefixes.
- **FR-002**: The system MUST preserve a human path-line rendering mode where
  changed leaves are shown with their full paths.
- **FR-003**: The command-line interface MUST expose explicit rendering
  selection so users can choose tree output or path-line output.
- **FR-004**: The command-line interface MUST expose or define tree art
  behavior so users can obtain Unicode-friendly output and a
  non-Unicode-safe output.
- **FR-005**: The default human output MUST be deterministic: tree render
  shape with ASCII tree art.
- **FR-006**: Tree rendering MUST preserve existing semantic content:
  side labels `A` and `B`, exact ADA/lovelace values, compact CBOR summaries,
  only-side values, and blueprint-decoded datum/redeemer fields.
- **FR-007**: Path-line rendering MUST remain compatible with the first
  release's meaning: every changed leaf can be read without parent context.
- **FR-008**: Invalid render mode or art values MUST produce a usage error
  before transaction inputs are read or decoded.
- **FR-009**: The design MUST evaluate existing tree rendering or
  diff-rendering libraries before implementation and record the dependency
  decision.
- **FR-010**: The renderer MUST consume the existing diff tree and MUST NOT
  recompute transaction comparison or blueprint decoding.
- **FR-011**: Tests MUST cover both render shape selection and tree art
  selection for representative object and array paths.
- **FR-012**: Tests MUST prove that two sibling differences under a shared
  parent are grouped under that parent in tree mode.

### Key Entities

- **Render Shape**: The high-level output structure selected by the user,
  such as tree hierarchy or flat path lines.
- **Tree Art**: The connector and indentation style used when render shape is
  tree, such as Unicode connectors or ASCII/plain connectors.
- **Rendered Diff Node**: A displayed branch or leaf derived from the existing
  structural diff result.
- **Changed Leaf**: A rendered difference with side `A` and side `B` values,
  an only-side value, or an equal-context marker when explicitly shown.

## Success Criteria

### Measurable Outcomes

- **SC-001**: A fixture with two sibling changes under one parent renders the
  parent path exactly once in tree mode.
- **SC-002**: The same fixture renders each changed leaf with a full path in
  path-line mode.
- **SC-003**: Every supported rendering selection is documented in CLI usage
  and has at least one automated test.
- **SC-004**: Invalid rendering selections fail without decoding transaction
  input files.
- **SC-005**: No existing value formatting regression occurs for ADA/lovelace
  amounts, CBOR summaries, or blueprint-decoded fields.

## Assumptions

- `tx-diff` remains a text CLI; colorized or interactive rendering is out of
  scope for this ticket.
- The existing structural diff model remains the source of truth.
- Because this package has a minimal-dependency constitution, any new
  rendering dependency must be justified before implementation.
- The first implementation may support a small finite set of modes and art
  styles; open-ended plugin rendering is out of scope.
- Unicode tree art is an explicit opt-in so CI logs, markdown snippets, and
  minimal terminals receive portable output by default.
