# Implementation Plan: Conway stake certificates and treasury-withdrawal proposals

**Branch**: `feat/conway-stake-treasury-withdrawal` (speckit feature
`042-conway-stake-treasury`) | **Date**: 2026-05-12 |
**Spec**: [spec.md](./spec.md) | **PR**: [#132](https://github.com/lambdasistemi/cardano-node-clients/pull/132)
**Input**: [spec.md](./spec.md)

**Spec Kit note**: this repo keeps the GitHub branch name above instead
of a numeric Spec Kit branch name. If `.specify/scripts/bash/check-prerequisites.sh`
rejects the branch, use `specs/042-conway-stake-treasury/` as the
feature directory explicitly.

## Status

**Completed**: Slices A-E. Certificate support, duplicate cert
coalescing, `registerAndVoteAbstain`, generic proposal support,
`proposeTreasuryWithdrawal`, CLI golden parity, and public export
coverage are implemented on the stacked branch
`042-upstream-proposal-slices`.

**Current**: Run the full `just ci` gate, then open a draft PR stacked
on `feat/conway-stake-treasury-withdrawal` without merging.

**Blockers**: Slice F remains pending. The Conway devnet smoke is still
outside this stacked PR slice.

## Summary

Extend the TxBuild DSL with two new instruction families — Conway
certificates (`certify`, `registerAndVoteAbstain`) and proposal
procedures (`propose`, `proposeTreasuryWithdrawal`) — and the
matching redeemer-indexing wiring (`ConwayCertifying`,
`ConwayProposing`). Proposal redeemers are guardrail-script redeemers,
not proposer/deposit-return witnesses. Mirror the existing `spend` /
`mint` / `withdraw` patterns end-to-end: `Peek` fixpoint for index
resolution, body-container-order collectors for redeemers, additive
changes only. Proof is three-tier per slice (property + golden vs
`cardano-cli` + live-devnet boundary smoke).

Detail is in [research.md](./research.md),
[data-model.md](./data-model.md),
[contracts/txbuild-conway-api.md](./contracts/txbuild-conway-api.md),
[quickstart.md](./quickstart.md).

## Technical Context

**Language/Version**: Haskell, GHC pinned by `cabal.project` (current
`ghc-9.12.x` per repo).
**Primary Dependencies**: `cardano-ledger-conway`, `cardano-ledger-api`,
`plutus-tx`, `operational`. All already in the `tx-build` library's
`build-depends` (`cardano-node-clients.cabal:39-65`).
**Storage**: N/A. DSL is pure; produces a `ConwayTx` for submission.
**Testing**: Hspec (property + unit), CBOR golden vectors against
`cardano-cli`, live devnet via `withCardanoNode`.
**Target Platform**: Linux + Nix dev shell; CI via `just ci`.
**Project Type**: Haskell library (infrastructure), per the
constitution's Principle III.
**Performance Goals**: No new hot path. Cert / proposal collectors run
once per assembly; same shape as `collectSpendRedeemers`.
**Constraints**: Additive API only (constitution + spec line 131-132).
No new dependency on `cardano-cli`; the existing CLI dependency is
already retired by this PR for downstream consumers.
**Scale/Scope**: ~300 lines of production code in `TxBuild.hs`,
~200 lines of test code split between `TxBuildSpec`,
`TxBuildGoldenSpec`, and the new `E2E/TxBuildConwaySpec`.

## Constitution Check

| Principle | Status | Note |
|-----------|--------|------|
| I. Channel-driven N2C clients | ok | DSL is producer-side; submission still goes through `LocalTxSubmission`. No new mini-protocol. |
| II. Devnet E2E testing | ok | Boundary smoke uses the existing `withCardanoNode` harness; LSQ queries assert ledger state. No mocks. |
| III. Minimal dependencies | ok | No new package. `cardano-ledger-conway` types re-exported from the existing import set. |
| IV. Test utilities are first-class | ok | `CertWitness`, `ProposalWitness`, smart constructors, and the re-exported Conway types are exposed from the `tx-build` library. |
| Quality gate: `just ci` passes | ok | `llm/reviews/132/gate.sh` is the inner-loop slice gate; finalization also runs `nix develop --quiet -c just ci` to satisfy the constitution. |

Re-evaluation after Phase 1: no new violations. No entry in the
Complexity Tracking table.

## Vertical slices (proof-first)

Each slice is one reviewed commit, bisect-safe, RED + GREEN folded
inside the commit. Tasks expand these in `tasks.md`.

1. **Slice A — cert combinator skeleton + redeemer indexing.**
   New `CertWitness` type, `Certify` instruction, `tsCerts` state,
   `collectCertRedeemers`, `assembleTx` patch for `certsTxBodyL` and
   the cert redeemer slot. Tests: property tests in `TxBuildSpec`
   covering the script and pub-key branches plus a property check on
   redeemer index against a generated cert list and the final body
   field.
   Acceptance criteria 1, 2. Behaviour: `certify` works for any
   Conway TxCert.

2. **Slice B — `registerAndVoteAbstain` smart constructor + golden.**
   Smart constructor delegates to `certify` with the combined
   register-and-vote-abstain ledger value. Golden test against a
   `cardano-cli conway stake-address
   registration-and-vote-delegation-certificate --always-abstain`
   vector under `test/fixtures/mainnet-txbuild/conway-042/`.
   Acceptance criterion 3.

3. **Slice C — proposal combinator skeleton + redeemer indexing.**
   `ProposalWitness`, `Propose` instruction, `tsProposals` state,
   `collectProposalRedeemers`, `assembleTx` patch for
   `proposalProceduresTxBodyL` and the proposal redeemer slot.
   Property test for guardrail script branch and no-script branch.
   Acceptance criterion 4.

4. **Slice D — `proposeTreasuryWithdrawal` smart constructor + golden.**
   Smart constructor delegates to `propose` with the
   `TreasuryWithdrawals` action. Golden test against the
   matching `cardano-cli conway governance action
   create-treasury-withdrawal` vector. Acceptance criterion 5.

5. **Slice E — public exports + ledger-type re-exports + haddock.**
   Wire the new symbols into the explicit export list of
   `Cardano.Node.Client.TxBuild`, re-export the Conway ledger types
   the consumer needs (per `contracts/txbuild-conway-api.md`), write
   haddock. Acceptance criterion 7. Internal slices A–D may declare
   symbols `Internal` until this slice opens them.

6. **Slice F — boundary smoke (`E2E.TxBuildConwaySpec`).**
   New e2e spec module: boots devnet, submits cert tx, asserts
   `DRepAlwaysAbstain` registration via LSQ, submits proposal tx,
   asserts the proposal appears in the proposals snapshot. Wired
   into `cardano-node-clients.cabal`'s `e2e-tests` stanza so the
   gate's `GATE_FULL=1` path picks it up. Acceptance criterion 6.

Each slice's RED proof is committed in the same git object as the
GREEN change. Where a property test pre-exists and the new behaviour
extends it, the diff to the test is the RED proof. Where the proof
artefact is a new file (e.g. a golden vector), the file is committed
alongside the implementation, *and* the test that consumes it is part
of the same commit so the slice fails closed if the implementation
regresses.

## Proof strategy

- **Property tests** (Hspec + QuickCheck): final-body-order invariants
  for cert and proposal redeemer indices against generated lists;
  pub-key certs and proposals without guardrail scripts emit no
  redeemer; `ScriptCert` / `GuardrailProposal` emit exactly one
  redeemer at the correct index.
- **Golden vectors**: equality of DSL-emitted cert/proposal body
  fields against artifact CBOR fixtures generated from `cardano-cli`.
  These fixtures are decoded as `ConwayTxCert ConwayEra` /
  `ProposalProcedure ConwayEra`, not as full transactions. Stored
  under `test/fixtures/mainnet-txbuild/conway-042/` with the exact CLI
  invocation recorded in `quickstart.md` for reviewer reproduction.
- **Boundary smoke**: live devnet end-to-end (`GATE_FULL=1`). Asserts
  the cert and proposal both land on chain and the ledger reports the
  expected state.

## Project Structure

### Documentation (this feature)

```text
specs/042-conway-stake-treasury/
├── spec.md
├── plan.md            # this file
├── research.md
├── data-model.md
├── contracts/
│   └── txbuild-conway-api.md
└── quickstart.md
```

### Source code touched

```text
lib-tx-build/
└── Cardano/Node/Client/
    └── TxBuild.hs                          # additive: state, ADT, smart ctors, collectors, exports

test/
├── Cardano/Node/Client/
│   ├── TxBuildSpec.hs                      # add property tests (slices A, C)
│   ├── TxBuildGoldenSpec.hs                # add golden cases (slices B, D)
│   └── E2E/TxBuildConwaySpec.hs            # NEW, slice F
└── fixtures/mainnet-txbuild/conway-042/
    ├── register-and-vote-abstain.cbor.hex
    ├── register-and-vote-abstain.inputs
    ├── treasury-withdrawal.cbor.hex
    └── treasury-withdrawal.inputs

cardano-node-clients.cabal                  # add new test modules under other-modules
llm/reviews/132/gate.sh                     # already in place
```

**Structure Decision**: Single-project Haskell layout; the `tx-build`
sublibrary already isolates the DSL from the rest of the package.

## Complexity Tracking

Empty. No constitution violations; no justified deviations.

## Open follow-ups (out of scope for this PR)

- Plain pub-key stake registration without combined vote delegation
  (#131 if needed).
- DRep registration, vote-only certificates, abstain/no-confidence
  to a specific DRep id, stake-pool registration.
- Conway governance actions other than `TreasuryWithdrawals`.
- `amaru-treasury-tx#83` (the withdrawal tx) and `#84` (the swap) —
  separate consumer slices, both built on the same DSL surface added
  here.
