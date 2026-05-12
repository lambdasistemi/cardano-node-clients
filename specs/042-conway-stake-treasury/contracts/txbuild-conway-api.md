# Contract — `Cardano.Node.Client.TxBuild` Conway additions

Public Haskell surface added by PR #132. All symbols land in the
existing module's explicit export list (`TxBuild.hs:21-90`). The DSL
type parameters `q` (query GADT) and `e` (caller error) are unchanged.

## Witness types

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
```

`CertWitness` has the same shape as `SpendWitness` / `WithdrawWitness`.
`ProposalWitness` models Conway's proposal script purpose: a
`ConwayProposing` redeemer is needed only when the proposal procedure's
governance action carries an optional guardrail script hash.

## Generic combinators

```haskell
-- | Emit a Conway certificate. Returns the final positional
-- index of the cert in the assembled body — the same index a
-- ledger validator sees.
certify
    :: ConwayTxCert ConwayEra
    -> CertWitness
    -> TxBuild q e Word32

-- | Emit a Conway proposal procedure. Returns the final
-- positional index of the proposal in the assembled body.
propose
    :: ProposalProcedure ConwayEra
    -> ProposalWitness
    -> TxBuild q e Word32
```

Both install a `Peek` node to resolve the index against the assembled
`ConwayTx`. Callers that need the index from inside a redeemer payload
use the existing fixpoint mechanism.

## Smart constructors (consumer-driven)

```haskell
-- | Register a stake credential and delegate its vote to the
-- always-abstain DRep target in one combined Conway cert.
-- The caller supplies the deposit Coin (read from pparams).
registerAndVoteAbstain
    :: Credential 'Staking
    -> Coin
    -> CertWitness
    -> TxBuild q e Word32

-- | Emit a TreasuryWithdrawals governance action as a single
-- proposal procedure.
proposeTreasuryWithdrawal
    :: Coin                      -- ^ proposal deposit (from pparams)
    -> RewardAccount             -- ^ deposit-return account
    -> Anchor                    -- ^ anchor (URL + content hash)
    -> Map RewardAccount Coin    -- ^ payee map: script reward acct → amount
    -> StrictMaybe ScriptHash    -- ^ optional guardrail script hash
    -> ProposalWitness
    -> TxBuild q e Word32
```

Both smart constructors call `certify` / `propose` internally with a
pre-built ledger value. The combined cert produced by
`registerAndVoteAbstain` is the
`registration-and-vote-delegation-certificate --always-abstain` shape
that `cardano-cli conway stake-address` emits.

For the first treasury-withdrawal consumer, pass `SNothing` and
`NoProposalScript`. If a later caller supplies `SJust guardrailHash`,
it must pass `GuardrailProposal redeemer` and attach the matching
guardrail script through `attachScript`.

## Re-exports

To avoid forcing callers to import three `cardano-ledger-*` modules
just to build cert and proposal payloads:

```haskell
-- from Cardano.Ledger.Conway.TxCert
ConwayTxCert (..)

-- from Cardano.Ledger.Conway.Governance
ProposalProcedure (..)
GovAction (..)
Anchor (..)

-- from Cardano.Ledger.Credential
Credential (..)

-- from Cardano.Ledger.Address
RewardAccount (..)

-- from Cardano.Ledger.Conway.Core / Governance
DRep (DRepAlwaysAbstain, DRepAlwaysNoConfidence, DRepCredential)
```

`ScriptHash`, `Coin`, `StrictMaybe`, and `Map` are already re-exported
or available via existing imports the consumer uses.

## Invariants

- The `Word32` returned by `certify`, `propose`,
  `registerAndVoteAbstain`, and `proposeTreasuryWithdrawal` is the
  final body-field index. It does not equal the DSL insertion order in
  general.
- `PubKeyCert` and `NoProposalScript` produce no redeemer entry.
  `ScriptCert` and `GuardrailProposal` produce exactly one redeemer
  entry pointing at the positional index above.
- Calling `attachScript` for the script's bytes is the caller's
  responsibility, identical to the existing `spendScript` /
  `mint` contract.
- The DSL does not query pparams; the deposit Coin is caller-supplied.
- All Conway-era types live behind `ConwayEra`; no era polymorphism
  is exposed.

## Backwards compatibility

Strictly additive:

- No existing combinator signature changes.
- No existing witness type changes.
- No existing test fixture changes (the new golden vectors live in a
  new subdirectory).
- `TxInstr q e` ADT gains two constructors; downstream pattern
  matches on `TxInstr` (if any exist outside the test suite) would
  warn but not fail because the GADT is consumed only inside the
  interpreter.

## Error surface

No new constructors on `BuildError`. Failure modes:

- Malformed cert / proposal payload → ledger rejection at submission,
  surfaced through the existing `Rejected` path of
  `Cardano.Node.Client.LocalTxSubmission`.
- Missing attached script for a `ScriptCert` / `GuardrailProposal` →
  same path as the existing `ScriptWitness` / `PlutusScriptWitness`
  cases.
- Insufficient deposit funds → standard balance failure from the
  existing `buildWith` flow.
