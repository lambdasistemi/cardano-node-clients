# Data Model: Tx Diff Named Collapse Views

## CollapseRules

Top-level YAML configuration.

- `version`: schema version, currently `1`.
- `views.raw`: `show` or `hide`; defaults to `show`.
- `collapse`: ordered list of named overlay rules.

## CollapseRule

Named semantic view over one list path.

- `name`: rendered child name, for example `swapOrders`.
- `at`: absolute diff path to a list, for example `body.outputs`.
- `match.required`: relative paths that must exist as changed leaves inside a
  list item for that item to be included in the view.

## Collapsed Leaf Group

Rendered leaf entry created from exact A/B equality.

- `indices`: one or more original list indexes, rendered as ranges when
  contiguous.
- `left`: rendered A value.
- `right`: rendered B value.

## Transformation

```text
List<Indexed DiffTree>
  -- select per named rule -->
List<Indexed MatchingDiffTree>
  -- keep required leaves -->
DiffTree<List<Indexed DiffLeaf>>
  -- group exact leaf equality -->
DiffTree<List<IndexRange DiffLeaf>>
```

The original list remains renderable as raw output.

When raw output is hidden, changed list items and tail insertions/deletions
that are not represented by any named rule remain renderable under their
original numeric indexes.
