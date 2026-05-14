# Implementation Plan: tx-diff Render Modes

**Branch**: `132-tx-diff-render-modes` | **Date**: 2026-05-14 |
**Spec**: [spec.md](./spec.md)
**Input**: Feature specification from
`specs/132-tx-diff-render-modes/spec.md`; GitHub issue #139.

## Status

**Completed**: Setup/dependency decision, RED renderer and CLI tests, tree
and path render implementation, CLI flag parsing, Conway expectation updates,
focused unit verification, and full local CI.

**Current**: Ready for PR review.

**Blockers**: None.

## Summary

Add an explicit rendering contract for `tx-diff`: tree-shaped human output
for readability, path-line output for scripts, and selectable tree art for
Unicode-capable terminals versus plain logs. The default is tree shape with
ASCII tree art. The implementation must keep comparison logic in the existing
diff tree and limit rendering changes to the presentation layer and CLI option
parsing.

## Technical Context

**Language/Version**: Haskell, GHC 9.12.3  
**Primary Dependencies**: Existing `containers`; add `tree-view` for Unicode
tree connector rendering, as recorded in [research.md](./research.md)
**Storage**: N/A  
**Testing**: Hspec via `just unit`; lint/format through `just ci`  
**Target Platform**: `tx-diff` CLI and library renderer API  
**Project Type**: Haskell library plus CLI executable  
**Performance Goals**: Rendering must be linear in the number of rendered
diff nodes and must not force traversal of equal subtrees  
**Constraints**: Preserve minimal dependencies; do not recompute transaction
diffs in the renderer; support non-Unicode output  
**Scale/Scope**: Human rendering of one `DiffNode` tree at a time

## Constitution Check

- **Channel-Driven N2C Clients**: Not applicable; this change is offline
  rendering only.
- **Devnet E2E Testing**: No node boundary is touched. Unit tests are the
  main proof; full `just ci` remains the merge gate.
- **Minimal Dependencies**: Active gate. Any new rendering dependency must be
  justified in research and in the implementation commit.
- **Test Utilities Are First-Class**: Renderer fixtures should stay in the
  unit test surface and remain reusable.

Initial result: PASS, with the dependency decision explicitly deferred to
Phase 0 research.

## Project Structure

### Documentation

```text
specs/132-tx-diff-render-modes/
├── spec.md
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   └── cli.md
├── checklists/
│   └── requirements.md
└── tasks.md
```

### Source Code

```text
lib/Cardano/Node/Client/TxDiff.hs
app/tx-diff/Main.hs
test/Cardano/Node/Client/TxDiff/CoreSpec.hs
test/Cardano/Node/Client/TxDiff/ConwaySpec.hs
cardano-node-clients.cabal
```

**Structure Decision**: Keep rendering in `TxDiff.hs` for this slice unless
the implementation becomes large enough to justify a dedicated renderer
module. CLI parsing stays in `app/tx-diff/Main.hs`.

## Phase 0: Research

Research output is captured in [research.md](./research.md).

Key decision:

- Use `containers` / `Data.Tree.drawForest` for ASCII connector style.
- Use `tree-view` for Unicode connector style.
- Keep comparison logic in the existing `DiffNode` traversal.
- Do not use `tree-diff` as the primary renderer because it is a diff engine
  and has a license mismatch concern for this project.

## Phase 1: Design

Design output:

- [data-model.md](./data-model.md)
- [contracts/cli.md](./contracts/cli.md)
- [quickstart.md](./quickstart.md)

## Implementation Approach

1. Add RED tests for render shape and tree art selection.
2. Add renderer option data types in the library.
3. Preserve the current path renderer behind an explicit mode.
4. Implement tree rendering from the existing `DiffNode`.
5. Wire CLI parsing and usage text.
6. Run focused unit tests, then full gate.

## Post-Design Constitution Check

PASS: implementation records a narrow, BSD-3-Clause,
Nix/Cabal-compatible dependency choice. The dependency addition must be part
of the same vertical commit as its tests and CLI behavior.
