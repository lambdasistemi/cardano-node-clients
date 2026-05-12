# Implementation Plan: Devnet node query support

**Branch**: `131-devnet-query-support`
**Spec**: [spec.md](./spec.md)
**Issue**: [#131](https://github.com/lambdasistemi/cardano-node-clients/issues/131)
**Base**: PR [#135](https://github.com/lambdasistemi/cardano-node-clients/pull/135)

## Status

**Completed**: Address helpers, provider/query-handle surface, N2C LSQ
queries, test-provider stubs, and the `Provider.N2C` devnet conformance
group; branch pushed and draft PR
[#137](https://github.com/lambdasistemi/cardano-node-clients/pull/137)
opened against PR #135.
**Current**: The remaining proof is the downstream DevNet story: submit
the governance action, wait for the next epoch, and observe the target
reward account funding through the provider queries.
**Follow-up**:
[amaru-treasury-tx#82](https://github.com/lambdasistemi/amaru-treasury-tx/issues/82)
owns the final governance smoke that consumes #135 + #137, submits the
setup governance transaction, waits for the next epoch, and observes
the reward-account balance increase.
**Blockers**: None for the query-side PR.

## Technical Context

**Language/Version**: Haskell, GHC through the repository Nix shell
**Primary Dependencies**: `cardano-ledger-*`,
`ouroboros-consensus`, `ouroboros-network`
**Testing**: Hspec unit tests, Hspec devnet E2E tests, `just ci`
**Target**: Public library API in `Cardano.Node.Client.Provider` plus
address helpers in `Cardano.Node.Client.Address`

## Constitution Check

- Channel-driven N2C clients: preserved; all live reads use the
  existing LocalStateQuery channel.
- Devnet E2E testing: add a real devnet provider smoke for the new
  boundary.
- Minimal dependencies: no new package dependencies expected.
- Test-first workflow: add failing tests before production changes.

## Design

1. Add `Cardano.Node.Client.Address` with small typed helpers:
   payment/stake credential extraction, reward-account construction,
   reward-account credential extraction, and key/script credential
   constructors.
2. Extend `Cardano.Node.Client.Provider` with:
   - a ledger summary containing current era text, chain point, tip
     slot, and epoch;
   - reward balance queries by reward account and by stake credential;
   - vote-delegatee query by stake credential;
   - treasury and governance-state queries.
3. Mirror each new one-shot provider field on `QueryHandle` so callers
   can make consistent acquired-session reads.
4. Implement the N2C backend with Conway LocalStateQuery constructors:
   current era, chain point, epoch, account state, filtered reward
   accounts, filtered vote delegatees, and governance state.
   Treasury uses `GetCBOR GetAccountState` and decodes the treasury
   field from the returned account-state payload so the provider does not
   depend on the reserve field decoding as a non-negative `Coin` on local
   devnets.
5. Keep existing tests and test providers compiling by supplying
   explicit unused stubs where tests do not touch the new fields.

## DevNet Governance Smoke Story

`amaru-treasury-tx#82` should consume this PR together with #135 and
prove the actual reward flow:

1. Pin `cardano-node-clients` to a stack containing #135 and #137.
2. Update the Amaru local provider stub for the additive Provider and
   QueryHandle fields.
3. Replace permanent `cardano-cli query` and `cardano-cli address info`
   use in the governance smoke with #137 Provider/address helpers.
4. Record the target script reward-account balance and submission epoch.
5. Build and submit the setup governance transaction through #135.
6. Wait until the ledger epoch is greater than the submission epoch.
7. Query the target reward account again and assert the balance
   increased by the requested treasury-withdrawal amount.

The smoke is not accepted if it only proves that LSQ queries return.
It must tie the observed reward balance to a submitted governance
action and the following epoch.

## Missing Work To Complete The Story

This PR leaves only the upstream query dependency ready. The story is
not complete until the downstream `amaru-treasury-tx#82` PR has these
vertical slices:

1. **Downstream stack pin and compile repair**: pin
   `cabal.project` to a `cardano-node-clients` commit containing #135
   and #137; add any needed `cardano-node-clients:devnet` dependency;
   update all local Provider stubs so the downstream repo compiles.
2. **RED governance smoke**: add a failing DevNet smoke/test that boots
   the short-epoch devnet, records the target script reward-account
   balance and epoch, then fails until a governance action is submitted
   and a later epoch funds that reward account.
3. **Governance setup submitter**: build and submit the setup
   transaction with #135 (`registerAndVoteAbstain` and
   `proposeTreasuryWithdrawal`) against the devnet faucet/genesis UTxO.
4. **Epoch wait and reward assertion**: poll #137
   `queryLedgerSnapshot` until `ledgerEpoch > submissionEpoch`, then
   use `queryRewardAccounts`/`queryStakeRewards` to assert the exact
   requested treasury-withdrawal amount arrived.
5. **Summary and gate**: emit a machine-readable summary with run
   directory, tx id, governance action id, target reward account,
   requested amount, before/after reward balances, submission epoch,
   observed epoch, and the `cardano-node-clients` commit; wire the
   smoke into an explicit `just devnet-smoke-governance` gate.

Do these as separate bisect-safe commits. Each commit must compile and
must include the test/gate that proves its slice.

## Verification

Run, in order:

```bash
nix develop --quiet -c cabal test cardano-node-clients:unit-tests -O0 --test-show-details=direct --test-option=--match --test-option=/Address/
nix develop --quiet -c cabal test cardano-node-clients:e2e-tests -O0 --test-show-details=direct --test-option=--match --test-option=/Provider.N2C/
nix develop --quiet -c just format
nix develop --quiet -c just ci
```
