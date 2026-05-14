# Implementation Plan: Tx Diff Named Collapse Views

**Branch**: `feat/tx-diff-named-yaml-collapse-views-for-list-diffs` | **Date**: 2026-05-14 | **Spec**: `specs/142-tx-diff-collapse-views/spec.md`  
**Input**: Feature specification from `specs/142-tx-diff-collapse-views/spec.md`

## Summary

Add an optional YAML-driven collapse pass to the existing tx-diff human tree
renderer. The exact structural diff remains unchanged. When a list path has
named collapse rules, each rule independently selects matching changed list
items, transposes configured relative diff leaves into a named view, and
groups equal A/B leaves by index ranges. Raw per-index rendering remains
available and defaults to visible; when raw is hidden, uncovered list diffs
remain visible under their original numeric indexes. Tree-mode changed leaves
render A and B on separate right-aligned lines.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.3  
**Primary Dependencies**: `aeson`, `containers`, `text`, `tree-view`, new
`yaml` dependency for YAML config parsing  
**Storage**: N/A  
**Testing**: Hspec + QuickCheck via `just unit` and full `just ci`  
**Target Platform**: Linux/macOS CLI  
**Project Type**: Haskell library + CLI executable  
**Performance Goals**: Linear in rendered changed list items and configured
required paths for normal tx-diff sizes  
**Constraints**: Preserve existing output without rules; no arithmetic
aggregation in this ticket  
**Scale/Scope**: Human rendering for Conway transaction diffs

## Constitution Check

- Use existing tx-diff core and renderer patterns.
- Add tests before production behavior.
- Keep release-surface changes narrow: one CLI flag and a parser.
- Do not introduce semigroup/formula semantics in this slice.

## Project Structure

### Documentation

```text
specs/142-tx-diff-collapse-views/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── collapse-rules.yaml.md
└── tasks.md
```

### Source Code

```text
lib/Cardano/Node/Client/TxDiff.hs
lib/Cardano/Node/Client/TxDiff/Cli.hs
app/tx-diff/Main.hs
test/Cardano/Node/Client/TxDiff/CoreSpec.hs
test/Cardano/Node/Client/TxDiff/CliSpec.hs
cardano-node-clients.cabal
```

**Structure Decision**: Keep the collapse data model and renderer integration
inside `Cardano.Node.Client.TxDiff` for the first slice because the feature is
render-only and operates on `DiffNode`.

## Status

**Completed**: Ticket #142 and follow-up ticket #143 created. Spec artifacts
written. Collapse rules parser, CLI flag, named overlay rendering, hidden-raw
preservation, and unit coverage implemented. Initial `just format`,
`just unit`, and `just ci` passed. Review refinement for hidden-raw remainder
rendering and A/B tree alignment completed.
**Current**: Ready for external review.
**Blockers**: None.

## Complexity Tracking

No constitution violations.
