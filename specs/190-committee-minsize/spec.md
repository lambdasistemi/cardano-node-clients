# Spec — Issue 190: stock devnet committee arrangement makes governance unenactable

## P1 user story

As a consumer of `withDevnet`, I need governance actions (ParameterChange, HardForkInitiation, etc.) proposed and voted on a fresh stock devnet to actually enact, so I can test version-sensitive and parameter-sensitive behavior without a private per-consumer genesis workaround.

## The defect

Stock `e2e-test/genesis/conway-genesis.json` ships `committeeMinSize: 7` with an empty `committee.members: {}`. Under Conway ratification rules, `committeeAccepted` requires the active committee size to meet `committeeMinSize`; with 0 active members against a minimum of 7, this is permanently unsatisfiable. Any governance action requiring committee acceptance (which includes `ParameterChange` and `HardForkInitiation`) sits through its full lifetime with valid DRep votes and a complete pulser run, and never enacts. The failure is silent: proposal-present, votes-registered, and epoch-advancing all look healthy; only the enacted parameter never changes.

## User stories

- **US1**: A consumer starts a stock `withDevnet` devnet, proposes and votes yes on a `ParameterChange`, and the parameter is enacted within the devnet's normal epoch cadence.
- **US2**: Existing consumers of `withDevnet` see no other behavior change — this is a genesis-arrangement fix, not an API change.

## Functional requirements

- **FR1**: `e2e-test/genesis/conway-genesis.json` gains one harness-generated constitutional committee member (cold + hot credential) and `committeeMinSize` set to `1` (matching the real committee size).
- **FR2**: The harness (`Devnet.hs`/`Setup.hs`) exposes whatever key material is needed to construct the committee hot-key authorization certificate and cast a committee vote from a consumer's own governance-transaction code (mirroring the pattern issue #187's `Governance.hs` already proved live).
- **FR3**: A committed test proves the fix: propose + vote + assert enactment of a real `ParameterChange` on a fresh stock devnet, asserted from queried protocol-parameters — never from logs.
- **FR4**: Genesis-change discipline: enumerate the exact fields changed in `conway-genesis.json`, assert old→new values, and confirm (e.g. via a diff against upstream field-by-field) that nothing else moved.

## Success criteria

- [ ] A ParameterChange proposed + voted on a fresh `withDevnet` devnet enacts (queried-parameter assertion).
- [ ] Issue #187's `HardForkInitiation` path (already landed via a per-consumer workaround, `workaround-for=lambdasistemi/cardano-node-clients#190`) has a stock committee capable of accepting it — i.e. the fix generalizes, even though #187 does not need to be re-touched as part of this ticket.
- [ ] No existing `withDevnet`/`withDevnetConfig` consumer's default (PV10, no governance action) behavior changes.

## Non-goals

- Re-deriving or refactoring #187's already-landed PV11 governance transition code (`Governance.hs`) — this ticket only fixes the genesis arrangement it depends on. #187's workaround note becomes stale/removable once this lands, but deleting it is not in scope here.
