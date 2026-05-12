# Tasks: Devnet node query support

## Phase 1 - RED tests

- [X] T001 Add unit tests for `Cardano.Node.Client.Address`.
- [X] T002 Add provider E2E expectations for ledger summary, treasury,
  governance state, reward balances, and vote delegatees.
- [X] T003 Run targeted tests and confirm the new tests fail before
  production code exists.

## Phase 2 - Provider API

- [X] T004 Add `Cardano.Node.Client.Address` and expose it from the
  main library.
- [X] T005 Extend `Provider`, `QueryHandle`, and
  `QueryHandleBackend` with the new query fields.
- [X] T006 Update test providers to stub the additive fields.

## Phase 3 - N2C backend

- [X] T007 Implement the new LocalStateQuery calls in
  `Cardano.Node.Client.N2C.Provider`.
- [X] T008 Keep one-shot fields delegating through `withAcquired`.
- [X] T009 Verify the devnet provider smoke runs against the N2C
  boundary.

## Phase 4 - PR handoff

- [X] T010 Run format and full CI.
- [X] T011 Commit a vertical, bisect-safe slice.
- [X] T012 Push `131-devnet-query-support` and open a draft PR with base
  `042-upstream-proposal-slices`.

## Phase 5 - Governance reward smoke story

- [X] T013 Replace the review-boundary prose with the actual downstream
  story: submit a treasury-withdrawal governance action on DevNet, wait
  for the next epoch, and assert the target reward account was funded.

## Phase 6 - Downstream DevNet proof

- [ ] T014 [US1] Create/update the downstream Spec Kit artifacts for
  Amaru issue #82 in
  `/code/amaru-treasury-tx/specs/007-devnet-governance-action/spec.md`,
  `/code/amaru-treasury-tx/specs/007-devnet-governance-action/plan.md`,
  and
  `/code/amaru-treasury-tx/specs/007-devnet-governance-action/tasks.md`
  so User Story 1 is exactly: submit the treasury-withdrawal governance
  action, wait for the next epoch, assert the target reward account was
  funded.
- [ ] T015 [US1] Pin `/code/amaru-treasury-tx/cabal.project` to a
  `cardano-node-clients` commit containing #135 and #137, refresh the
  `--sha256`, and add any needed `cardano-node-clients:devnet` or
  `cardano-node-clients:tx-build` dependency in
  `/code/amaru-treasury-tx/amaru-treasury-tx.cabal`.
- [ ] T016 [US1] Add or centralize downstream Provider test stubs in
  `/code/amaru-treasury-tx/test/unit/Amaru/Treasury/TestProvider.hs`
  and update existing stubs in
  `/code/amaru-treasury-tx/test/unit/Amaru/Treasury/Registry/VerifySpec.hs`,
  `/code/amaru-treasury-tx/test/unit/Amaru/Treasury/Tx/SwapWizardSpec.hs`,
  and
  `/code/amaru-treasury-tx/test/unit/Amaru/Treasury/Tx/WithdrawWizardSpec.hs`
  for the additive #137 Provider/QueryHandle fields.
- [ ] T017 [US1] Replace the downstream direct LSQ reward helper in
  `/code/amaru-treasury-tx/lib/Amaru/Treasury/Backend/N2C.hs` and
  `/code/amaru-treasury-tx/app/amaru-treasury-tx/Main.hs` with #137
  Provider queries (`queryRewardAccounts` or `queryStakeRewards`) so
  reward observation goes through the same boundary as the smoke.
- [ ] T018 [US1] Add a RED unit test for epoch waiting and reward delta
  in
  `/code/amaru-treasury-tx/test/unit/Amaru/Treasury/DevNet/GovernanceSmokeSpec.hs`:
  a fake Provider reports epoch N and reward R before submission, then
  epoch N+1 and reward R+amount, and the assertion returns the funded
  summary.
- [ ] T019 [US1] Implement the pure/IO-free smoke state machine in
  `/code/amaru-treasury-tx/lib/Amaru/Treasury/DevNet/GovernanceSmoke.hs`
  with functions for reading `ledgerEpoch`, recording before/after
  reward balances, waiting for `ledgerEpoch > submissionEpoch`, and
  asserting the exact requested amount.
- [ ] T020 [US1] Add a RED integration smoke entry point in
  `/code/amaru-treasury-tx/app/devnet-governance-smoke/Main.hs` and its
  cabal executable stanza in
  `/code/amaru-treasury-tx/amaru-treasury-tx.cabal`; it must boot/use a
  short-epoch devnet, record pre-submit reward state, and fail until the
  setup transaction is actually submitted.
- [ ] T021 [US1] Implement the setup transaction builder in
  `/code/amaru-treasury-tx/lib/Amaru/Treasury/DevNet/GovernanceSetup.hs`
  using #135 `registerAndVoteAbstain` and
  `proposeTreasuryWithdrawal`, funded by the devnet faucet/genesis UTxO
  and targeting the Amaru script reward account.
- [ ] T022 [US1] Submit the setup transaction in
  `/code/amaru-treasury-tx/app/devnet-governance-smoke/Main.hs` through
  the N2C submitter, capture the tx id and governance action id, and
  wait until the tx is observable before starting the epoch wait.
- [ ] T023 [US1] Complete the smoke in
  `/code/amaru-treasury-tx/app/devnet-governance-smoke/Main.hs` by
  waiting for `ledgerEpoch > submissionEpoch`, querying the target
  reward account through #137 Provider queries, and failing unless
  `afterReward - beforeReward == requestedWithdrawal`.
- [ ] T024 [US1] Emit the machine-readable summary from
  `/code/amaru-treasury-tx/app/devnet-governance-smoke/Main.hs` to the
  run directory with tx id, governance action id, reward account,
  requested amount, before/after rewards, submission epoch, observed
  epoch, tip slot, and `cardano-node-clients` commit.
- [ ] T025 [US1] Wire `/code/amaru-treasury-tx/justfile` with
  `devnet-smoke-governance` and add
  `/code/amaru-treasury-tx/scripts/smoke/devnet-governance` so the
  proof is one command and cannot pass by running zero examples.
- [ ] T026 [US1] Run
  `nix develop --quiet -c just unit GovernanceSmoke`,
  `nix develop --quiet -c just devnet-smoke-governance`, and
  `nix develop --quiet -c just ci` in `/code/amaru-treasury-tx`; commit
  only after all three gates pass.

## Phase 7 - Commit discipline for the downstream PR

- [ ] T027 [US1] Commit the downstream work as vertical, bisect-safe
  slices: stack pin/compile repair; RED smoke harness; setup tx
  submitter; epoch wait plus reward assertion; summary/gate wiring.
- [ ] T028 [US1] Keep `amaru-treasury-tx#82` draft until
  `just devnet-smoke-governance` proves the funded reward account in a
  later epoch, not merely that LSQ queries return.
