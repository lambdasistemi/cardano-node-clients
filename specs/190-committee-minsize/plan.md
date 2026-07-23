# Plan — Issue 190: stock devnet committee arrangement

## Tech stack

- Language & harness: Haskell (`cardano-node-clients:devnet`, `e2e-tests`)
- Ledger: `cardano-ledger-api`/`cardano-ledger-conway`
- Reference implementation: issue #187's `Governance.hs` (landed on `feat/187-devnet-pv11`, unmerged) already proves the CC-hot-key-authorization + committee-vote pattern live against a real devnet. Port the relevant shape, don't re-derive from scratch.

## Slices

### Slice A — Stock genesis fix + enactment proof
- Patch `e2e-test/genesis/conway-genesis.json`: one CC committee member (cold credential in `committee.members`, real hot-key authorization at runtime), `committeeMinSize: 7 -> 1`. Enumerate every field touched.
- Add whatever minimal key-material exports (`Devnet.hs`/`Setup.hs`) a consumer needs to authorize the committee hot key and cast its vote — mirror #187's `Governance.hs` pattern (`ConwayAuthCommitteeHotKey`, `CommitteeVoter`) rather than reinventing it.
- New E2E test (`test/Cardano/Node/Client/E2E/*Spec.hs`): starts a stock `withDevnet` devnet, proposes a real `ParameterChange` (a benign parameter, not tied to PV11 — e.g. bump `maxTxSize` or similar low-risk param), authorizes + votes yes from DRep and CC, asserts the parameter enacted via queried protocol-parameters within the devnet's normal epoch cadence.
- This is the whole ticket — single slice, single commit.
