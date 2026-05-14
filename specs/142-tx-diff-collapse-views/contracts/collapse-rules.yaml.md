# Collapse Rules YAML Contract

## Version 1

```yaml
version: 1

views:
  raw: show   # show | hide; optional, defaults to show

collapse:
  - name: swapOrders
    at: body.outputs
    match:
      required:
        - coin
        - datum.fields.4.fields.0.2
        - datum.fields.4.fields.1.2
```

## Fields

- `version`: required schema version. Version `1` is the only supported value.
- `views.raw`: optional raw-list rendering policy. `show` is the default;
  `hide` suppresses the raw branch only where a named view exists.
- `collapse`: optional list of named overlay rules.
- `collapse[*].name`: required rendered semantic view name, for example
  `swapOrders`.
- `collapse[*].at`: required absolute diff path to an array/list node, for
  example `body.outputs`.
- `collapse[*].match.required`: non-empty list of required relative paths
  inside each changed list item.

## Path Syntax

Paths are dot-separated object keys and numeric list indexes. They are written
against the open transaction diff tree after any blueprint decoding has
substituted datum or redeemer data.

- `at` paths are absolute from the diff root, for example `body.outputs`.
- `match.required` paths are relative to one item under the `at` list, for
  example `coin` or `datum.fields.4.fields.0.2`.
- The first slice has no wildcard, predicate, arithmetic, or schema language in
  the rule file.

## Matching And Grouping

A rule applies at its `at` path when that path is a changed list. For each
changed list item, the item is selected when all `match.required` paths exist
as changed leaves inside that item.

Selected leaves are transposed so the list index moves down to the changed
leaf. Exact equal A/B leaf pairs are grouped and rendered as index ranges:

```text
outputs
`- swapOrders
   `- coin
      +- 0..4
      |  +- A: 12371.863798 ADA (12371863798 lovelace)
      |  `- B: 12503.280000 ADA (12503280000 lovelace)
      `- 32
         +- A: 12371.863797 ADA (12371863797 lovelace)
         `- B:   8166.545306 ADA (8166545306 lovelace)
```

Rules are independent overlays. Matching an item in one rule does not remove it
from any other rule, so semantic views may intersect.

## Raw View Policy

With `views.raw: show`, the original list diff remains available under a `raw`
branch when named views exist at that list path.

With `views.raw: hide`, the raw branch is omitted, but unrepresented diffs are
not dropped. Changed leaves, insertions, and deletions not represented by a
named view render directly under their original numeric indexes.

## Rendering Contract

Tree-mode changed leaves render A and B as separate child lines. Values are
right-aligned against each other within that changed leaf.

This contract has no formula, sum, delta, or semigroup fields. Aggregation is
tracked separately.

## Render Shape

With `views.raw: hide`, named views render before numeric remainder indexes.
Each changed leaf keeps the transaction values as aligned children:

```text
body
`- outputs
   +- swapOrders
   |  `- coin
   |     `- 0..4
   |        +- A: 12371.863798 ADA (12371863798 lovelace)
   |        `- B: 12503.280000 ADA (12503280000 lovelace)
   `- 33
      `- coin
         +- A: 1041728.494694 ADA (1041728494694 lovelace)
         `- B: 1041836.734694 ADA (1041836734694 lovelace)
```
