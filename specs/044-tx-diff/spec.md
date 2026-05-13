# Feature Specification: Conway Transaction Diff

**Feature Branch**: `feat/tx-diff-136`  
**Created**: 2026-05-13  
**Status**: Draft  
**Input**: GitHub issue 136 plus current direction: traverse Conway
transactions in lockstep, collect differences, and stop recursion whenever
the paired values are equal.

## User Scenarios & Testing

### User Story 1 - Find the changed transaction path (Priority: P1)

A user compares two Conway transactions and needs the tool to point at the
transaction path that changed, without dumping unrelated equal subtrees.

**Why this priority**: This is the core utility. If a fee, validity interval,
output, redeemer, or datum differs, the user needs the smallest useful changed
path and the two values.

**Independent Test**: Compare a fixture transaction against a copy with one
known field changed. The report includes that path and excludes unrelated
equal branches.

**Acceptance Scenarios**:

1. **Given** two identical Conway transactions, **When** they are compared,
   **Then** the result has no differences and the traversal does not inspect
   children below the equal transaction root.
2. **Given** two Conway transactions that differ only in fee, **When** they
   are compared, **Then** the result identifies only the fee path with side
   `A`, side `B`, and no unrelated body fields expanded.
3. **Given** two Conway transactions that differ in one output coin, **When**
   they are compared, **Then** the output path keeps shared context such as
   the output position or key and isolates the changed coin value.

---

### User Story 2 - Preserve common map and collection context (Priority: P2)

A user compares structured values inside a transaction and needs common keys
and collection context factored out instead of repeated under full `A` and
`B` copies.

**Why this priority**: Transaction data often contains maps, outputs, assets,
and application-level records. Repeating whole structures makes the diff hard
to read.

**Independent Test**: Compare two object-like values with common keys,
changed keys, and keys present on only one side. The result separates
`common`, `changed`, `onlyA`, and `onlyB` recursively.

**Acceptance Scenarios**:

1. **Given** two maps with equal key/value pairs and one changed key, **When**
   they are compared, **Then** equal pairs appear as shared context and only
   the changed key recurses.
2. **Given** a nested map where an inner value differs, **When** it is
   compared, **Then** the same factoring rule is applied to the inner map.
3. **Given** a sequence with the same element on both sides at an aligned
   position, **When** it is compared, **Then** that element is not traversed
   further.

---

### User Story 3 - Use blueprints at application boundaries (Priority: P3)

A user provides one or more Plutus blueprints so datum and redeemer leaves can
be decoded into open application-level values before diffing.

**Why this priority**: The ledger transaction structure alone cannot name the
fields inside application data. Blueprints are the external context available
to make those leaves useful without inventing Haskell domain types.

**Independent Test**: Compare two transactions with a redeemer or datum
change and a matching blueprint. The diff descends through the decoded open
value and uses blueprint labels where the match is unambiguous.

**Acceptance Scenarios**:

1. **Given** a matching blueprint for a datum or redeemer, **When** the data
   differs, **Then** the diff traverses the decoded open value and shows the
   changed labelled path.
2. **Given** multiple blueprints that could match the same application data,
   **When** the data differs, **Then** the result marks the match as
   ambiguous and does not choose one silently.
3. **Given** no matching blueprint, **When** datum or redeemer data differs,
   **Then** the result reports the raw Plutus data at that leaf without
   failing the whole comparison.

### Edge Cases

- Equal root transactions must end the traversal immediately.
- Equal large subtrees must end traversal at that subtree before reading or
  rendering children.
- Unequal values with no known traversal must be reported as an atomic
  difference at the current path.
- Map keys present only on one side must be reported as `onlyA` or `onlyB`.
- Sequence alignment must be deterministic; if no stable key exists, use
  index order and report insertions or deletions at the relevant index.
- The tool must not infer business names for transaction sides. Inputs are
  `A` and `B` unless labels are explicitly supplied.
- The tool must not sum arbitrary application values or assume semigroup
  semantics. Deltas are allowed only for known scalar ledger units.
- Numeric values must preserve exact ledger units.

## Requirements

### Functional Requirements

- **FR-001**: The system MUST compare exactly two Conway transactions,
  identified as side `A` and side `B`.
- **FR-002**: The comparison MUST traverse paired nodes in lockstep. In this
  document, "parallel" means side-by-side structural traversal, not threaded
  execution.
- **FR-003**: For every paired node, the comparison MUST check equality before
  any child traversal.
- **FR-004**: When a paired node is equal, the comparison MUST stop at that
  node and MUST NOT inspect or render its children.
- **FR-005**: When a paired node is unequal and has a known Conway traversal,
  the comparison MUST recurse into corresponding fields and collect child
  differences.
- **FR-006**: When a paired node is unequal and has no known traversal, the
  comparison MUST report an atomic `changed` value at the current path.
- **FR-007**: Map-like values MUST be compared by key union and separated into
  `common`, `changed`, `onlyA`, and `onlyB`.
- **FR-008**: Map-like `changed` values MUST recurse with the same equality
  gate and factoring rules.
- **FR-009**: Sequence-like values MUST be compared using a deterministic
  alignment rule. Shared aligned values use the equality gate; unmatched
  values become `onlyA` or `onlyB`.
- **FR-010**: Conway transaction traversal MUST cover transaction body fields
  first, including inputs, reference inputs, collateral inputs, outputs, fee,
  validity interval, mint, withdrawals, required signers, and collateral
  totals where present.
- **FR-011**: Witness traversal MUST be opt-in. When enabled, it MUST include
  scripts, datum values, redeemers, and auxiliary data where the ledger value
  exposes them.
- **FR-012**: Blueprint input MUST be advisory context. It may improve datum
  and redeemer traversal, but transaction decoding must not depend on it.
- **FR-013**: When a blueprint match is unambiguous, datum and redeemer data
  MUST be converted to an open value tree and compared with the same traversal
  rules as the rest of the diff.
- **FR-014**: When blueprint matching is missing or ambiguous, the diff MUST
  retain enough metadata for the user to see why no labelled traversal was
  used.
- **FR-015**: The output MUST be derived from transaction inputs, CLI options,
  and provided blueprints only. It MUST NOT invent transaction names,
  application labels, totals, or semantic grouping rules not present in those
  inputs.
- **FR-016**: Human output MUST be a rendering of the collected diff tree, not
  a separate hand-authored summary.
- **FR-017**: Machine-readable output, when provided, MUST mirror the same
  collected diff tree and preserve exact numeric values.
- **FR-018**: The command MUST exit with status `0` when no differences are
  collected and non-zero when differences are collected.

### Key Entities

- **Transaction Side**: One of the two compared inputs, named `A` or `B`.
- **Diff Path**: A deterministic path from the transaction root to the node
  being compared.
- **Diff Node**: A collected result for a path. It can be equal, changed,
  present only on `A`, present only on `B`, or a parent containing child diff
  nodes.
- **Conway Traversal**: The finite set of Conway transaction fields the tool
  knows how to descend into safely.
- **Open Application Value**: A JSON-like tree decoded from Plutus data using
  blueprint context when available. It remains untyped and open.
- **Blueprint Context**: One or more Plutus blueprints used only to label and
  decode datum/redeemer leaves.

## Success Criteria

### Measurable Outcomes

- **SC-001**: Comparing identical transactions reports zero differences and
  proves through tests that child traversal is not performed below the equal
  root.
- **SC-002**: A one-field transaction change produces exactly one changed
  path, plus only the common context needed to locate that path.
- **SC-003**: Map and nested map comparisons separate common, changed, only-A,
  and only-B content recursively in unit tests.
- **SC-004**: A changed output coin is reported at the coin path without
  duplicating the full output object on both sides.
- **SC-005**: A matching blueprint allows a datum or redeemer field change to
  be reported below the decoded application field path.
- **SC-006**: Missing or ambiguous blueprint context produces an explicit
  fallback result instead of a misleading labelled diff.
- **SC-007**: Exact integer ledger quantities are preserved in the machine
  model and human rendering.

## Assumptions

- The first implementation targets Conway transactions only.
- The initial traversal is finite and hand-authored for Conway ledger types;
  generic diff libraries are not relied on to discover all fields.
- The equality gate uses the ledger value equality available at each known
  node.
- A stable output format will be chosen after the diff tree model is covered
  by tests.
- Blueprint decoding is best-effort and never changes the transaction value
  being compared.
