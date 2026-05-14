# Research: Tx Diff Named Collapse Views

## Findings

- The existing renderer already builds a trie from `DiffNode` paths. Collapse
  can be implemented as a pre-render insertion strategy without changing the
  diff engine.
- The correct model is overlay projection, not partitioning. A rule does not
  consume list items; each rule independently selects matching items.
- The user clarified that the list dimension moves to the differences. In
  implementation terms, a rule transforms selected changed list children from
  `[(index, DiffTree)]` into a named tree of required relative paths, where
  each leaf contains grouped indexed A/B diffs.
- Existing raw rendering must remain available for auditability. When rules
  exist at a list path, raw output can be shown under a `raw` child or hidden
  by config.
- YAML is the right user-facing format for the rule file. The codebase already
  uses `aeson`; the Haskell `yaml` package can parse YAML into `FromJSON`
  instances with minimal custom code.

## Decision

Use this minimal YAML shape:

```yaml
version: 1
views:
  raw: show
collapse:
  - name: swapOrders
    at: body.outputs
    match:
      required:
        - coin
        - datum.fields.4.fields.0.2
        - datum.fields.4.fields.1.2
```

## Alternatives Considered

- **Branch-level grouping by whole diff-tree equality**: rejected because the
  user wants the list moved down to diff leaves, not a group around repeated
  whole branches.
- **Rules as partitions**: rejected because semantic views may intersect.
- **Semigroup aggregation in the same ticket**: rejected and tracked in #143.
