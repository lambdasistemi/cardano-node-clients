# Tasks: Tx Diff Named Collapse Views

**Input**: `specs/142-tx-diff-collapse-views/`  
**Prerequisites**: `spec.md`, `plan.md`, `research.md`,
`data-model.md`, `contracts/collapse-rules.yaml.md`

## Phase 1: Specification

- [x] T001 Create GitHub issue #142 for named YAML collapse views.
- [x] T002 Create follow-up GitHub issue #143 for semigroup/formula aggregation.
- [x] T003 Write Spec Kit artifacts under `specs/142-tx-diff-collapse-views/`.

## Phase 2: Tests First

- [x] T004 [P] Add core renderer tests for one named collapse view moving
  `outputs` indexes down to `coin` and nested datum leaves in
  `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.
- [x] T005 [P] Add core renderer tests showing intersecting rules are overlays
  in `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.
- [x] T006 [P] Add core renderer tests for `views.raw: hide` in
  `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.
- [x] T007 [P] Add CLI parser tests for `--collapse-rules FILE` in
  `test/Cardano/Node/Client/TxDiff/CliSpec.hs`.
- [x] T008 [P] Add a regression test that `views.raw: hide` still renders
  list diffs not represented by any named collapse view under original numeric indexes in
  `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.

## Phase 3: Implementation

- [x] T009 Add collapse rules data types and YAML parser to
  `lib/Cardano/Node/Client/TxDiff.hs`.
- [x] T010 Add collapse rule fields to `HumanRenderOptions` and thread options
  through tree rendering in `lib/Cardano/Node/Client/TxDiff.hs`.
- [x] T011 Implement named overlay selection, required-path extraction, leaf
  transposition, and exact leaf grouping in `lib/Cardano/Node/Client/TxDiff.hs`.
- [x] T012 Preserve unrepresented list diffs, insertions, and deletions under
  original numeric indexes when `views.raw: hide` suppresses only the fully represented raw view in
  `lib/Cardano/Node/Client/TxDiff.hs`.
- [x] T013 Add `--collapse-rules FILE` parsing to
  `lib/Cardano/Node/Client/TxDiff/Cli.hs`.
- [x] T014 Load the YAML rules file in `app/tx-diff/Main.hs`.
- [x] T015 Add `yaml` dependency in `cardano-node-clients.cabal`.

## Phase 4: Verification

- [x] T016 Run `nix develop --quiet -c just format`.
- [x] T017 Run `nix develop --quiet -c just unit`.
- [x] T018 Run `nix develop --quiet -c just ci`.

## Phase 5: Review Refinement

- [x] T019 [P] Add RED tests for flattened numeric remainder rendering and
  vertical right-aligned A/B tree values in
  `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.
- [x] T020 Flatten hidden-raw remainder rendering to original numeric children
  in `lib/Cardano/Node/Client/TxDiff.hs`.
- [x] T021 Render tree-mode A/B values as right-aligned child lines in
  `lib/Cardano/Node/Client/TxDiff.hs`.
- [x] T022 Regenerate the gist collapse outputs.
- [x] T023 Re-run `nix develop --quiet -c just format`.
- [x] T024 Re-run `nix develop --quiet -c just unit`.
- [x] T025 Re-run `nix develop --quiet -c just ci`.
