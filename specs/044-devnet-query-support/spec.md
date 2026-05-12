# 044 — Devnet node query support

Issue: [#131](https://github.com/lambdasistemi/cardano-node-clients/issues/131)
Base PR: [#135](https://github.com/lambdasistemi/cardano-node-clients/pull/135)
Status: Draft - governance reward smoke story pending

## Context

`amaru-treasury-tx` needs local-devnet smoke tests to observe chain
state through typed Haskell node-to-client APIs instead of using
`cardano-cli query` and `cardano-cli address info` as the boundary.
PR #135 adds the Conway transaction-construction side for stake
registration and treasury-withdrawal proposals. This slice adds the
query-side companion on top of #135.

The missing story is concrete: boot a short-epoch Conway devnet, submit
the treasury-withdrawal governance action, wait for the next epoch, and
prove through typed queries that the target reward account received the
funds. Query success alone is not the proof.

## User Scenarios & Testing

### User Story 1 - Governance action funds reward account next epoch (P1)

A downstream smoke test boots a local Conway devnet, builds and submits
the treasury-withdrawal governance setup transaction, waits until the
ledger advances past the submission epoch, and observes that the target
script reward account has received the requested funds.

**Independent Test**: The DevNet smoke records the target reward-account
balance before submission, submits the governance action, waits for the
next epoch, then queries the same reward account through
`Cardano.Node.Client.Provider` and asserts the balance increased by the
expected withdrawal amount. The test fails if no governance action was
submitted, if the epoch did not advance, or if the reward balance did
not change.

### User Story 2 - Devnet smoke reads ledger state through Provider (P1)

A downstream smoke test boots a local Conway devnet, submits setup
transactions, and reads the resulting state through
`Cardano.Node.Client.Provider`.

**Independent Test**: An E2E provider test calls the N2C provider for
current era, tip slot, epoch, protocol parameters, treasury, governance
state, reward balances, and vote delegation data without shelling out to
`cardano-cli`.

### User Story 3 - Reward accounts are queryable by typed credentials (P1)

A caller can ask for key-backed and script-backed reward-account
balances using ledger types and receives a typed map of balances for
registered accounts.

**Independent Test**: The devnet test queries both a key reward account
and a script reward account. Unregistered accounts return no balances
and do not error.

### User Story 4 - Address and script credentials do not require CLI parsing (P2)

A caller can extract payment and stake credentials from ledger
addresses, and can build key/script credentials and reward accounts in
Haskell.

**Independent Test**: Unit tests cover base addresses, enterprise
addresses, reward-account construction, and account credential
extraction.

## Requirements

- **FR-001**: The provider MUST continue exposing UTxO-by-address and
  UTxO-by-TxIn queries as typed ledger values.
- **FR-002**: The provider MUST expose reward-balance queries for sets
  of reward accounts and for sets of stake credentials.
- **FR-003**: The provider MUST expose vote-delegation queries for
  stake credentials so the Conway abstain delegation can be observed.
- **FR-004**: The provider MUST expose current era, chain point, tip
  slot, and epoch as a typed summary.
- **FR-005**: The provider MUST expose protocol parameters, treasury
  value, and Conway governance state needed by the treasury-withdrawal
  smoke.
- **FR-006**: All new provider queries MUST be available both as
  one-shot provider fields and acquired-session handle fields.
- **FR-007**: Address helper functions MUST cover payment credential
  extraction, stake credential extraction, reward-account construction,
  and reward-account credential extraction.
- **FR-008**: Existing provider callers MUST keep compiling with only
  additive API changes.
- **FR-009**: The downstream DevNet smoke MUST submit a real Conway
  treasury-withdrawal governance action before claiming governance
  success.
- **FR-010**: The downstream DevNet smoke MUST wait until the ledger
  epoch is greater than the submission epoch before checking reward
  delivery.
- **FR-011**: The downstream DevNet smoke MUST query the target reward
  account before and after the epoch transition and assert the expected
  balance increase.
- **FR-012**: A smoke that only proves that LSQ queries return
  successfully MUST NOT satisfy the governance proof.

## Success Criteria

- **SC-001**: Unit tests for address helpers pass.
- **SC-002**: A devnet E2E test exercises the new N2C provider queries
  without invoking `cardano-cli`.
- **SC-003**: `nix develop --quiet -c just ci` passes.
- **SC-004**: The work is delivered in a separate draft PR stacked on
  #135 and is not merged by this session.
- **SC-005**: The downstream governance smoke in
  `amaru-treasury-tx#82` passes against a stack containing #135 and
  #137 by submitting the governance action and observing the reward
  account funding in the following epoch.

## Out Of Scope

- Implementing the Conway setup transaction constructors. PR #135 owns
  that work; the downstream smoke still has to use those constructors to
  submit a real transaction.
- Querying every Conway governance substructure. This slice exposes the
  typed `GovState ConwayEra` boundary and specific reward/delegation
  summaries needed by the current smoke.
