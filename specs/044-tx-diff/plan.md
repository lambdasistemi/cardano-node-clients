# Implementation Plan: Conway Transaction Diff

**Branch**: `feat/tx-diff-136` | **Date**: 2026-05-13 |
**Spec**: `specs/044-tx-diff/spec.md`

## Summary

Start over with a small structural diff core for Conway transactions. The core
walks two values in lockstep, checks equality before descending, and collects
a diff tree. Rendering is downstream of that tree. Blueprint support is
limited to enriching datum and redeemer leaves with open, labelled values
before those leaves are diffed.

## Technical Context

**Language/Version**: Haskell, GHC2021  
**Primary Dependencies**: Existing Cardano ledger packages, `aeson` for an
open value representation, existing test stack  
**Storage**: N/A  
**Testing**: Hspec unit tests through `just unit`  
**Target Platform**: Existing library and CLI package surface  
**Project Type**: Library plus optional CLI  
**Performance Goals**: Equal subtrees should cost one equality check and no
child traversal. Diffs should avoid rendering full equal subtrees.  
**Constraints**: Conway only for the first version. No generic magic requiring
missing instances. No invented application semantics.

## Design

### Diff Core

Define a small internal diff tree before any renderer:

```text
DiffNode
  path
  status: same | changed | onlyA | onlyB | parent
  value: optional atomic value for same/changed/only-side leaves
  children: optional child diff nodes for parent values
  context: optional common fields needed to locate changed children
```

The central algorithm is:

```text
diff(path, A, B):
  if A == B:
    return same(path, summary(A))

  if knownChildren(path, A, B):
    return parent(path, diff each paired child)

  return changed(path, A, B)
```

The important rule is ordering: equality is checked before `knownChildren`.
This must be unit-tested with an instrumented traversal fixture, not only by
inspection.

### Conway Traversal

Start with a finite Conway traversal table rather than a generic derivation.

Initial fields:

- transaction body
- inputs
- reference inputs
- collateral inputs
- outputs
- fee
- validity interval
- mint
- withdrawals
- required signers
- total collateral
- witnesses only when enabled

For each field, use the real ledger value for equality. Only after inequality
does the traversal expose smaller children. If a ledger type has no safe child
traversal yet, keep it atomic at that path.

### Maps And Collections

Map-like values use key union:

- equal shared key/value pairs become common context;
- unequal shared keys recurse under `changed`;
- keys only on side `A` become `onlyA`;
- keys only on side `B` become `onlyB`.

Sequences use deterministic alignment. Prefer stable ledger keys where they
exist, otherwise use index order. Shared aligned elements still pass through
the equality gate before any descent.

### Blueprint Boundary

Blueprints are loaded as optional context. They do not change transaction
decoding and they do not create Haskell domain types.

At datum/redeemer leaves:

1. Try to match a blueprint using available validator context.
2. If exactly one match exists, decode Plutus data into an open value tree.
3. Diff that open tree with the same equality-first traversal.
4. If no match or multiple matches exist, record the fallback reason and keep
   the raw Plutus value atomic.

The open value tree should be JSON-like: object, array, constructor, integer,
bytes, text. Schema labels may rename fields, but unknown schema areas keep
positional names.

### Rendering

The renderer consumes the diff tree. It must not recompute comparison logic.

Initial human rendering should show:

- changed paths;
- only the common context needed to locate changed children;
- side names `A` and `B`;
- exact integer ledger quantities;
- no transaction names not supplied by the user.

Machine output can be added after the diff tree tests pass. If added, it must
serialize the same diff tree instead of introducing another comparison model.

## Project Structure

```text
lib/Cardano/Node/Client/TxDiff.hs
test/Cardano/Node/Client/TxDiffSpec.hs
app/tx-diff/Main.hs
specs/044-tx-diff/
```

The first implementation should keep the executable thin. Parser, traversal,
diff tree, blueprint matching, and rendering belong in library code covered by
unit tests.

## Quality Gate

Use the existing project gate for the first pass:

```bash
just unit
```

Before any final claim, run the relevant focused unit tests after the last
code change. Run broader project checks before pushing.
