# 042 — Conway stake certificates and treasury-withdrawal proposals

PR: [#132](https://github.com/lambdasistemi/cardano-node-clients/pull/132)
Issue: [#130](https://github.com/lambdasistemi/cardano-node-clients/issues/130)
Status: Draft (orchestrator)

## Context

`amaru-treasury-tx` runs a local-devnet smoke that proves the protocol
treasury → script reward account → Amaru withdraw transaction → treasury
script UTxO path. Today the smoke shells out to `cardano-cli conway
stake-address registration-and-vote-delegation-certificate`,
`cardano-cli conway governance action create-treasury-withdrawal`, and
`cardano-cli conway transaction build/sign/submit` to prepare the setup
transactions before the Amaru-side flow can run. This works but keeps a
permanent `cardano-cli` boundary inside what should be a typed-Haskell
test harness.

The TxBuild DSL (`lib-tx-build/Cardano/Node/Client/TxBuild.hs`,
shipped by #41) already covers Conway-era inputs, outputs, mint,
withdrawals, validity bounds, metadata, signatures, attached scripts,
and the balance/ExUnits loop. It does **not** yet cover Conway
certificates or proposal procedures.

This spec defines the smallest set of additions that lets
`amaru-treasury-tx#82` build and submit the Conway setup transaction
through TxBuild without `cardano-cli`. Subsequent slices (#83
withdrawal, #84 swap) will consume the same DSL surface — they are out
of scope for this PR.

## Scope (first slice)

Implementation: extend the TxBuild DSL with two new instruction
families and the supporting redeemer-indexing wiring.

- **Certificates** — add a `certify` family that emits Conway
  certificates, with witness selection (pub-key or Plutus script
  redeemer) mirroring `SpendWitness` / `WithdrawWitness`. The only
  certificate shape required by the first consumer is the script-stake
  *register-and-vote-delegation-to-always-abstain* combined cert.
  A pub-key variant of the same cert is exposed because the same DSL
  constructor handles both credentials (script branch carries a
  redeemer, pub-key branch does not).
- **Proposal procedures** — add a `propose` family that emits Conway
  proposal procedures. The only governance action required by the
  first consumer is `TreasuryWithdrawals` with a deposit-return
  credential, an anchor, a target script reward account, and a
  lovelace transfer amount. Conway proposal redeemers are for optional
  guardrail scripts, not for the proposer/deposit-return credential;
  the first consumer uses `SNothing` guardrail and therefore no
  proposal redeemer.
- **Redeemer indexing** — extend the redeemer collection helpers and
  `assembleTx` so `ConwayCertifying (AsIx i)` / `ConwayProposing (AsIx i)`
  purposes are emitted with the correct positional index (the index a
  ledger validator sees, derived from the final body container order in
  `certsTxBodyL` / `proposalProceduresTxBodyL`).
- **Re-exports** — re-export from `Cardano.Node.Client.TxBuild` the
  Conway ledger types a caller needs to build the cert and proposal
  payloads (credentials, anchors, gov-action constructors) so
  downstream consumers don't have to import three nested
  `cardano-ledger-*` modules just to call the new combinators.

Out of scope:

- Plain pub-key stake registration (not combined with vote delegation).
  Comes back in #131 if the smoke needs it.
- DRep registration, vote-only certificates, abstain/no-confidence
  delegation to a specific DRep id, stake-pool registration.
- Other Conway governance actions (parameter changes, hard-fork,
  no-confidence, update committee, new constitution, info action) —
  none are required by the consumer slice.
- The actual treasury-withdrawal *withdrawal* transaction (that is
  #83 on `amaru-treasury-tx`). This PR proves the certificate and
  proposal reach the chain; consuming the proposal is the next slice.
- N2C submission helpers. TxBuild produces a `ConwayTx`; the existing
  `Cardano.Node.Client.LocalTxSubmission` channel submits it.

## User-visible API (proposed)

Inside `Cardano.Node.Client.TxBuild`:

```haskell
data CertWitness
    = -- | Pub-key stake credential, no redeemer.
      PubKeyCert
    | -- | Script stake credential with a typed redeemer.
      forall r. (ToData r) => ScriptCert r

data ProposalWitness
    = -- | No proposal script witness. Use for proposals without
      -- a guardrail script.
      NoProposalScript
    | -- | Guardrail script with a typed redeemer.
      forall r. (ToData r) => GuardrailProposal r

-- Generic emit: caller assembles the Conway TxCert directly.
certify :: ConwayTxCert ConwayEra -> CertWitness -> TxBuild q e Word32

-- Smart constructor for the only cert shape this PR needs.
-- Registers the stake credential and delegates the vote to
-- the always-abstain target in a single cert.
registerAndVoteAbstain
    :: Credential 'Staking
    -> Coin                     -- deposit (read from pparams by caller)
    -> CertWitness
    -> TxBuild q e Word32

-- Generic emit: caller assembles the Conway ProposalProcedure directly.
propose :: ProposalProcedure ConwayEra -> ProposalWitness -> TxBuild q e Word32

-- Smart constructor for the only proposal shape this PR needs.
proposeTreasuryWithdrawal
    :: Coin                                -- proposal deposit
    -> RewardAccount                       -- deposit-return account
    -> Anchor                              -- anchor (url + data hash)
    -> Map RewardAccount Coin              -- payees (script reward acct → amount)
    -> StrictMaybe ScriptHash              -- optional guardrail script
    -> ProposalWitness
    -> TxBuild q e Word32
```

The `Word32` returned by each combinator is the final positional
index of the cert/proposal in the final tx body — same pattern as
`spend`/`payTo`/`mint` use today. Callers that need to reference the
index from a downstream script (typical Plutus pattern) resolve it
through the existing `Peek` fixpoint mechanism the combinators install.

`assembleTx` populates `certsTxBodyL` and `proposalProceduresTxBodyL`,
and `collectCertRedeemers` / `collectProposalRedeemers` produce
`(ConwayCertifying (AsIx i), (data, ExUnits 0 0))` /
`(ConwayProposing (AsIx i), (data, ExUnits 0 0))` redeemer entries
for the script-witnessed slots. Cert indices are computed against the
`StrictSeq` stored in `certsTxBodyL`; proposal indices are computed
against the `OSet` stored in `proposalProceduresTxBodyL`. The
implementation must read the final assembled body fields rather than
assuming DSL insertion order.

Backwards compatibility: only additive. No existing TxBuild combinator
changes shape. No existing test fixture changes.

## Acceptance criteria

The PR is acceptable when:

1. **Cert combinator (script branch)** — `certify` + `ScriptCert r`
   produces a `ConwayTx` whose `certsTxBodyL` contains the supplied
   cert and whose `rdmrsTxWitsL` contains a `ConwayCertifying (AsIx i)`
   redeemer pointing at the right `r` payload, with `i` equal to the
   cert's position in the final `certsTxBodyL` field. Property test in
   `Cardano.Node.Client.TxBuildSpec`.
2. **Cert combinator (pub-key branch)** — `certify` + `PubKeyCert`
   produces a body cert and **no** `ConwayCertifying` redeemer. Property
   test in `Cardano.Node.Client.TxBuildSpec`.
3. **Combined register-and-vote-abstain** — `registerAndVoteAbstain`
   for a script credential emits exactly one cert whose
   serialised CBOR matches a `cardano-cli conway stake-address
   registration-and-vote-delegation-certificate --always-abstain`
   golden vector (golden test in
   `Cardano.Node.Client.TxBuildGoldenSpec`).
4. **Proposal combinator (guardrail script branch)** — `propose` +
   `GuardrailProposal` produces a `proposalProceduresTxBodyL` entry plus
   a matching `ConwayProposing (AsIx i)` redeemer when the proposal's
   governance action carries a guardrail script hash. `NoProposalScript`
   produces no `ConwayProposing` redeemer. Property test.
5. **Treasury-withdrawal proposal** — `proposeTreasuryWithdrawal`
   produces a proposal procedure whose CBOR matches a `cardano-cli
   conway governance action create-treasury-withdrawal` golden vector
   (same inputs: deposit, deposit-return account, anchor, single
   payee → amount, no guardrail). Golden test.
6. **Devnet boundary smoke** — `Cardano.Node.Client.E2E.TxBuildConwaySpec`
   boots the existing short-epoch devnet, submits a tx that registers
   a script stake credential via `registerAndVoteAbstain`, queries
   the ledger state and asserts the script credential is registered
   with `DRepAlwaysAbstain` as its delegated DRep, then submits a
   second tx with a treasury-withdrawal proposal and asserts the
   proposal is visible in the proposals snapshot.
7. **Public API is exported** — the spec's combinators and types are
   in the explicit export list of `Cardano.Node.Client.TxBuild`,
   with haddock per the haskell skill.
8. **Process** — every code commit is a vertical bisect-safe slice
   (RED + GREEN folded) per the `pr` skill. Plan and tasks are
   reviewed before code. `llm/reviews/132/gate.sh` passes (with
   `GATE_FULL=1` for the boundary smoke) before finalization, and the
   final reviewer gate runs `nix develop --quiet -c just ci` to satisfy
   the project constitution.

## Boundary smoke

The DSL is pure, but the consumer chain (`amaru-treasury-tx#82`) talks
to a live node. The boundary smoke runs against the project's
existing devnet harness so the indices and CBOR shape are validated
end-to-end against a real Conway-era ledger, not just unit
expectations. See `llm/reviews/132/gate.sh` (env `GATE_FULL=1`).

## Risks

- **Index drift.** Cardano-ledger validates redeemer indices against
  the position in the final body containers (`StrictSeq` for certs,
  `OSet` for proposal procedures). The redeemer indices the DSL emits
  must match the position the validator sees.
  Mitigation: same pattern `collectSpendRedeemers` and
  `collectMintRedeemers` already use — compute the index by inspecting
  the assembled body field, not against the raw insertion order of the
  DSL program. Property test on a generated cert/proposal list catches
  drift.
- **Conway TxCert shape churn.** `cardano-ledger-conway` revised the
  cert ADT during the era's stabilisation. We are pinned to a
  specific `cardano-ledger-conway` index-state via the existing
  `cabal.project` and CHaP pins; bumping CHaP is out of scope for
  this PR.
- **Anchor data hash.** `Anchor` carries a `SafeHash` of fetched
  metadata. The DSL takes the hash as input — fetching/hashing
  metadata is the caller's job, not TxBuild's.
- **Guardrail scripts.** Conway introduced an optional guardrail
  script reference on treasury-withdrawal actions. The first
  consumer's flow uses `SNothing` (no guardrail). The combinator
  exposes the slot so callers that need it later don't pay a
  signature change.

## Inputs / outputs

Inputs the DSL needs from the caller (no new context queries):

- `Credential 'Staking` of the script stake credential.
- The script bytes (attached via existing `attachScript`).
- The deposit amount (from pparams; caller already queries pparams
  for the existing TxBuild flow).
- `RewardAccount` for proposal deposit-return and for the payee.
- `Anchor` (URL + content hash) for the proposal.
- The Plutus redeemers (`ToData` instances) for the two script
  witnesses.

Outputs:

- A `ConwayTx` ready to be signed by the caller's existing key
  material and submitted through the existing
  `Cardano.Node.Client.LocalTxSubmission` channel.

## Quality gate

`llm/reviews/132/gate.sh`:

- `cabal build all -O0`
- `cabal test cardano-node-clients:unit-tests -O0`
- `cabal test cardano-node-clients:tx-build-tests -O0`
- `fourmolu -m check` on all tracked `*.hs`
- `hlint` on all tracked `*.hs`
- `cabal-fmt -c cardano-node-clients.cabal`
- `cabal test cardano-node-clients:e2e-tests` matched on the new
  `TxBuildConwaySpec` when `GATE_FULL=1`.
- Finalization-only: `nix develop --quiet -c just ci`.

Boundary smoke is gated behind `GATE_FULL=1` for the inner loop;
required green before finalization.
