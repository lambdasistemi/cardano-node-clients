# 042 — Data Model

The TxBuild DSL is the model; this document records the additions and
how they map to the assembled `ConwayTx`.

## New DSL state

`TxState` (in `TxBuild.hs`, internal) gains two fields. They are
append-only lists in DSL insertion order; `assembleTx` converts them
into the ledger body containers. Index resolution reads back the final
assembled body fields rather than assuming insertion order.

```haskell
data TxState e = TxState
    { ...
    , tsCerts     :: [(ConwayTxCert ConwayEra, CertWitness)]
    , tsProposals :: [(ProposalProcedure ConwayEra, ProposalWitness)]
    }
```

## New instructions

Added to `TxInstr q e` (in `TxBuild.hs`, internal GADT):

```haskell
Certify
    :: ConwayTxCert ConwayEra
    -> CertWitness
    -> TxInstr q e Word32

Propose
    :: ProposalProcedure ConwayEra
    -> ProposalWitness
    -> TxInstr q e Word32
```

Each instruction is followed by a `Peek` node that resolves the final
body-field index from the assembled body — same mechanism that
`spend` / `payTo` already use.

## Witness types (public)

```haskell
data CertWitness
    = PubKeyCert
    | forall r. (ToData r) => ScriptCert r

data ProposalWitness
    = NoProposalScript
    | forall r. (ToData r) => GuardrailProposal r
```

`CertWitness` mirrors `SpendWitness` /`WithdrawWitness` from
`TxBuild.hs:247-263`. `ProposalWitness` models the Conway proposal
script purpose: proposal redeemers are for optional guardrail scripts,
not for the proposer or deposit-return credential. The existential `r`
lets the GADT carry heterogeneous redeemer types in one instruction
stream.

## Redeemer indexing

Two new collectors live next to the existing three.

```haskell
collectCertRedeemers
    :: [(ConwayTxCert ConwayEra, CertWitness)]
    -> [(ConwayPlutusPurpose AsIx ConwayEra, (Data ConwayEra, ExUnits))]

collectProposalRedeemers
    :: [(ProposalProcedure ConwayEra, ProposalWitness)]
    -> [(ConwayPlutusPurpose AsIx ConwayEra, (Data ConwayEra, ExUnits))]
```

Index rule: take the position in the final body container that the
ledger will hold. For certs, that is the `StrictSeq` stored in
`certsTxBodyL`; for proposals, that is the `OSet` stored in
`proposalProceduresTxBodyL`. The same body-order pattern that
`collectSpendRedeemers` uses against `Set.toAscList allIns`
(`TxBuild.hs:1605-1613, 1630-1643`) applies here.

Pub-key cert witnesses and `NoProposalScript` produce no redeemer
entry.

`ExUnits` are emitted as `ExUnits 0 0`; the balance loop fills in
realistic values during the existing `draftWith` /
`buildWith` flow (`TxBuild.hs:749-832`).

## Body assembly

`assembleTx` is extended to populate two additional fields after the
existing five (`inputs`, `outputs`, `mint`, `withdrawals`, fee /
collateral):

- `certsTxBodyL .~ <StrictSeq of tsCerts>`
- `proposalProceduresTxBodyL .~ <OSet of tsProposals>`

The redeemer map gains the union of `collectCertRedeemers tsCerts` and
`collectProposalRedeemers tsProposals`; the existing integrity-hash
recomputation (`TxBuild.hs:798-824`) covers them automatically because
it hashes the whole `Redeemers` map.

## Public smart-constructor surface

Full signatures land in `contracts/txbuild-conway-api.md`; the model
view is:

- `certify` and `propose` accept a fully-formed ledger value and a
  witness, return the final body-field index.
- `registerAndVoteAbstain` accepts a stake credential, the deposit
  Coin (caller queries pparams), and a witness, and emits one
  combined ledger cert.
- `proposeTreasuryWithdrawal` accepts deposit, return account, anchor,
  payee map, optional guardrail script hash, and a guardrail witness,
  and emits one `TreasuryWithdrawals` proposal procedure. The first
  consumer passes `SNothing` with `NoProposalScript`.

## Golden vector layout

Place new fixtures under
`test/fixtures/mainnet-txbuild/conway-042/`:

```
test/fixtures/mainnet-txbuild/conway-042/
├── register-and-vote-abstain.cbor.hex
├── register-and-vote-abstain.inputs
├── treasury-withdrawal.cbor.hex
└── treasury-withdrawal.inputs
```

Generation is reviewer-reproducible: each vector is paired with a
shell snippet (under `quickstart.md`) that invokes `cardano-cli` with
the exact inputs the test asserts on and extracts the artifact's
`cborHex`. Golden tests decode those artifact CBOR values as a
`ConwayTxCert ConwayEra` or `ProposalProcedure ConwayEra`, then compare
them to the cert/proposal body field emitted by the DSL. These are not
full-transaction fixtures.

## E2E ledger-state assertions

`Cardano.Node.Client.E2E.TxBuildConwaySpec` queries the live devnet
through the existing `provider`:

- After tx 1 (cert): query `DState` via LSQ; assert the script stake
  credential is in the registration map and its delegated DRep is
  `DRepAlwaysAbstain`.
- After tx 2 (proposal): query the proposals snapshot; assert one
  `TreasuryWithdrawals` proposal procedure with the exact deposit,
  return account, anchor, and payee map exists.

The exact LSQ query names are confirmed during the implement slice
(the existing E2E test already calls `queryUTxOs`; the cert / proposal
queries land alongside).

## Out-of-scope state changes

- No new fields on `BuildOptions` and no change to the public
  `Interpret` / `InterpretIO` interfaces.
- No change to the existing redeemer collectors. The patch in
  `assembleTx` is additive: append new redeemer entries to the
  existing list before integrity hashing.
- No change to `BuildError`; cert and proposal failures surface as
  ordinary balance / submission errors already covered.
