# Tasks: Tx Diff Input Resolution

**Input**: `specs/150-tx-diff-input-resolution/`
**Prerequisites**: `spec.md`, `plan.md`

Each task in Phase 2 onward is one vertical, bisect-safe commit that
contains its own RED test and GREEN implementation. Tasks are ordered.
Phase markers (`[A]`–`[F]`) match the slice letters in `plan.md`.

## Phase 1: Specification

- [x] T001 Create GitHub issue #150 (already exists).
- [x] T002 Write Spec Kit `spec.md` under `specs/150-tx-diff-input-resolution/`.
- [x] T003 Write Spec Kit `plan.md` under `specs/150-tx-diff-input-resolution/`.
- [ ] T004 Write Spec Kit `tasks.md` (this file).
- [ ] T005 Write `specs/150-tx-diff-input-resolution/data-model.md` describing
  the `Resolver` record, `resolveChain` contract, and resolved-inputs map.
- [ ] T006 Write `specs/150-tx-diff-input-resolution/contracts/cli.md`
  enumerating the new flags, mutual requirements, and exit codes.
- [ ] T007 Write `specs/150-tx-diff-input-resolution/quickstart.md` with two
  worked examples: Blockfrost and local devnet N2C.

## Phase 2: Diff Core Accepts Resolved Inputs [A]

- [ ] T010 Add a RED unit test in
  `test/Cardano/Node/Client/TxDiff/CoreSpec.hs` that constructs two
  identical Conway transactions whose first input is `(txId, ix)` and
  passes a `txDiffResolvedInputs` map containing one synthetic `TxOut`. The
  test asserts the rendered tree under `body.inputs.0.resolved` exposes
  the four child paths (`address`, `coin`, `datum`, `referenceScript`),
  while the existing atomic `txIn` value is preserved at
  `body.inputs.0.txIn`.
- [ ] T011 Add a RED unit test that with `txDiffResolvedInputs` empty, the
  byte-for-byte rendered tree for the existing fixture is unchanged from
  the current snapshot stored in
  `test/Cardano/Node/Client/TxDiff/CoreSpec.hs`.
- [ ] T012 GREEN: add `txDiffResolvedInputs :: Map TxIn (TxOut ConwayEra)`
  to `TxDiffOptions`, default to empty, thread through
  `diffConwayTxWith`, and change `ConwayTxInValue` projection to consult
  the map. Commit message: `feat: tx-diff core supports resolved inputs`.

## Phase 3: Resolver Abstraction And Chain Semantics [B]

- [ ] T020 Add RED unit tests in
  `test/Cardano/Node/Client/TxDiff/ResolverSpec.hs` covering:
  empty chain returns `(empty, empty)`; single resolver returns its map
  unchanged; two-resolver chain merges with second only seeing the
  unresolved set; partially-resolved tail marks unresolved inputs with
  every resolver name that was tried.
- [ ] T021 GREEN: create `lib/Cardano/Node/Client/TxDiff/Resolver.hs` with
  `Resolver`, `resolveChain`, and an exported `noResolver` helper for the
  empty chain. Wire the module into `cardano-node-clients.cabal`. Commit
  message: `feat: tx-diff resolver chain`.

## Phase 4: N2C Resolver [C]

- [ ] T030 Add RED unit test in `ResolverSpec.hs` that wraps a fake
  `Provider IO` whose `queryUTxOByTxIn` returns a fixed map and asserts
  the wrapped resolver returns the same map. Add a second case where the
  fake returns a subset and asserts the unresolved set is exactly the
  missing inputs.
- [ ] T031 GREEN: add
  `lib/Cardano/Node/Client/TxDiff/Resolver/N2C.hs` exporting
  `fromProvider :: Provider IO -> Resolver`. Commit message:
  `feat: tx-diff N2C resolver`.
- [ ] T032 Add RED CLI-level integration test (in `CliSpec.hs` or a small
  new `MainResolverSpec.hs`) that fails fast when `--resolve-n2c` is set
  without `--network-magic`, and vice versa.
- [ ] T033 GREEN: extend the CLI parser in
  `lib/Cardano/Node/Client/TxDiff/Cli.hs` to require the pair. Commit
  message: `feat: tx-diff --resolve-n2c flag parsing`.

## Phase 5: Web2 Blockfrost Resolver [D]

- [ ] T040 Decide and pin the HTTP dependency. If `http-client` is in the
  current haskell.nix package set, use it; otherwise pick the smallest
  available substitute. Record the choice in `data-model.md`.
- [ ] T041 Add RED tests in
  `test/Cardano/Node/Client/TxDiff/Web2Spec.hs` against a local fake HTTP
  server (using `warp` if available; otherwise the test starts a thread
  with `network`'s `Network.Socket` directly):
  - Happy path returns the expected `(TxIn, TxOut)`.
  - HTTP 404 marks the input unresolved.
  - Malformed JSON marks the input unresolved.
  - A single `TxId` referenced twice triggers exactly one HTTP call.
- [ ] T042 GREEN: add `lib/Cardano/Node/Client/TxDiff/Resolver/Web2.hs`
  exporting `blockfrost :: Manager -> URL -> Maybe ApiKey -> Resolver`.
  Commit message: `feat: tx-diff Blockfrost web2 resolver`.
- [ ] T043 Add RED CLI tests covering `--resolve-web2 URL`,
  `--web2-api-key-file PATH`, malformed URL rejection, and the case where
  `--web2-api-key-file` is omitted.
- [ ] T044 GREEN: extend the CLI parser for the web2 flag group. Commit
  message: `feat: tx-diff --resolve-web2 flag parsing`.

## Phase 6: CLI Wiring And Diagnostics [E]

- [ ] T050 Add a RED integration test in
  `test/Cardano/Node/Client/TxDiff/MainResolverSpec.hs` that runs the
  `Main` CLI flow (via a small exported helper, not by spawning the
  process) with one synthetic resolver and asserts the stderr diagnostic
  for each unresolved input matches:
  `tx-diff: input <txId>#<ix> not resolved by [<resolver>, ...]`.
- [ ] T051 Add a RED test that with both `--resolve-n2c` and
  `--resolve-web2` configured, the N2C resolver is asked first and the
  web2 resolver is asked only for the leftovers (using two fake
  resolvers from the resolver module).
- [ ] T052 GREEN: extract a pure `mkResolverChain` helper from
  `Main.hs`, wire CLI flags to resolvers, run the chain before
  `diffConwayTxInputWith`, emit stderr diagnostics. Commit message:
  `feat: tx-diff Main integrates resolver chain`.
- [ ] T053 Add a RED test confirming exit-code 2 on pre-flight failure
  (bad N2C socket; obviously malformed web2 URL).
- [ ] T054 GREEN: add the startup validations described in `plan.md` to
  `Main.hs`. Commit message: `feat: tx-diff pre-flight resolver
  validation`.

## Phase 7: Documentation [F]

- [ ] T060 Update `docs/executables/tx-diff.md` to describe the two new
  flag groups, the resolver chain order (N2C first), exit codes, and
  privacy / trust notes (web2 leaks tx-ids to a third party; N2C sees
  only unspent UTxOs). Commit message: `docs: tx-diff input resolution
  flags`.

## Phase 8: Verification

- [ ] T070 `nix develop --quiet -c just format`.
- [ ] T071 `nix develop --quiet -c just unit`.
- [ ] T072 `nix develop --quiet -c just ci`.
- [ ] T073 Push, update PR #151 description with the final tour of
  changes, flip from draft to ready-for-review once CI is green.

## TDD / DDD Folding Note

In solo mode, the RED-only state is never pushed. Each task pair
`(RED test, GREEN implementation)` folds into one commit using `git add`
+ `git commit` after the test passes locally. The commit message is the
GREEN message; the body explains the proof. No `fixup` or `wip` commits.
