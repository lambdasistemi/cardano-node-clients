# TxDiff

`Cardano.Node.Client.TxDiff` is the structural comparison engine behind the
[`tx-diff` executable](../executables/tx-diff.md).

The module has two jobs:

- turn Conway transactions into an open diff tree that can include
  application-level datum and redeemer values
- render that tree in human-oriented forms without losing the original
  transaction structure

## Architecture

The comparison pipeline is deliberately split into three layers:

1. Decode each transaction input into a Conway transaction.
2. Project the transaction into an open value tree.
3. Traverse both trees in parallel and stop descending when equality proves a
   subtree is identical.

That last point matters. Equality is the guardrail that prevents the renderer
from drowning the user in unchanged structure. Only changed, inserted, and
deleted branches survive into the `DiffNode` tree.

## Open Values

The renderer does not try to preserve the full Haskell type of every ledger
field. It uses an open value shape:

- objects for named fields
- arrays for ordered ledger lists
- scalars for numbers, text, hashes, summaries, and rendered ledger values

This is intentional. Transaction users reason about the transaction shape, but
application-level datum and redeemer schemas are open-ended. A Plutus blueprint
can decode part of that world into named fields, and the diff tree can embed
those fields without needing a new Haskell type for each contract.

## Blueprint Boundary

Blueprint decoding happens before rendering. If a datum or redeemer can be
decoded unambiguously by the provided blueprints, raw Plutus data is replaced
with the decoded open value. If decoding fails or is ambiguous, the value stays
raw.

This keeps the invariant simple: rendering always consumes one open diff tree.
It does not special-case contract data after the diff has already been built.

## Collapse Rules

Collapse rules are a render-time overlay for list diffs. They do not alter the
core comparison.

For each rule:

1. Find the changed list at `collapse[*].at`.
2. Select changed list items where all `match.required` paths exist.
3. Keep only those required changed leaves.
4. Move the original list indexes down to each leaf.
5. Group exact equal A/B leaf pairs into index ranges.
6. Insert the result under the rule name.

The raw list can still be rendered under `raw`, or hidden with
`views.raw: hide`. Hiding raw does not hide unrepresented diffs; they remain
under their original numeric indexes.

Rules are overlays rather than partitions. Two rules may match the same item
because each name represents a semantic view, not ownership of a diff.

## Rendering

Tree rendering inserts changed leaves as path nodes with separate `A:` and
`B:` child rows. The values are right-aligned per changed leaf:

```text
fee
+- A:  1
`- B: 20
```

The executable defaults to ASCII tree art. Unicode tree art is available for
terminals and renderers that preserve it.

## Planned Boundaries

Two planned extensions keep the same architectural shape:

- **WASM support** should reuse the open diff tree and renderer contracts while
  replacing the executable boundary with a WebAssembly-callable API.
- **Input resolution through cardano-node N2C** should add an optional
  context-acquisition layer before rendering. The diff core should still
  compare explicit transactions; N2C resolution enriches what the renderer can
  explain about inputs that are only referenced by `TxIn`.

Keeping these as boundaries around the open diff tree avoids mixing network IO,
ledger lookup, or browser packaging concerns into the structural comparison
logic.

## User Manual

Use the executable manual for CLI flags, collapse-rule YAML, tutorials, and
troubleshooting:

- [`tx-diff` executable manual](../executables/tx-diff.md)
