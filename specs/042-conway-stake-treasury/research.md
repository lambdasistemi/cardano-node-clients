# 042 — Phase 0 Research

Source of truth: the implementation patterns the new code must mirror.
Citations are `path:line` in this worktree.

## 1. TxBuild DSL shape

`lib-tx-build/Cardano/Node/Client/TxBuild.hs` is an `operational`-style
`Program (TxInstr q e)` over a GADT instruction set
(`TxBuild.hs:280-331`). The instruction ADT carries 14 constructors today
(`Spend`, `Reference`, `Collateral`, `Send`, `MintI`, `Withdraw`,
`SetMetadata`, `ReqSignature`, `AttachScript`, `SetValidFrom`,
`SetValidTo`, `SetCollReturn`, `Peek`, `Valid`, `Ctx`). The DSL is
parameterised by an opaque query GADT `q` and a caller-chosen error
type `e`.

### Existing witness types (`TxBuild.hs:247-263`)

- `SpendWitness = PubKeyWitness | forall r. ToData r => ScriptWitness r`
- `MintWitness = forall r. ToData r => PlutusScriptWitness r` (script-only;
  there is no pub-key mint path).
- `WithdrawWitness = PubKeyWithdraw | forall r. ToData r => ScriptWithdraw r`

All three follow the same shape: a pub-key constructor that carries no
redeemer, and a script constructor existentially packing the `r` so the
ADT can hold many different redeemer types in one instruction stream.

### Peek fixpoint (`TxBuild.hs:303-325`, `504-507`)

`Peek :: (ConwayTx -> Convergence a) -> TxInstr q e a` with
`Convergence a = Iterate a | Ok a` (`TxBuild.hs:220-226`). Smart
constructors that need to return a *final* positional index emit a
structural instruction (e.g. `Spend ...`) followed by a `Peek` that
inspects the assembled tx and returns the final body-field index. The
interpreter iterates assembly until every `Peek` returns `Ok`, so each
combinator hands the caller a `Word32` that is guaranteed correct
against the body field the ledger will validate (`TxBuild.hs:347, 360,
382, 394, 415`).

This is the mechanism the new cert / proposal combinators reuse.

### `assembleTx` (`TxBuild.hs:749-832`)

Folds `TxState` into a `ConwayTx` in this order:

1. Inputs: `Set.union tsSpends extraIns` → `inputsTxBodyL`.
2. Outputs: `toList tsOuts` (insertion order, not sorted) → `outputsTxBodyL`.
3. Mint: fold `tsMints` via `addMint` (`TxBuild.hs:1705-1715`).
4. Withdrawals: `collectWithdrawalEntries`
   (`TxBuild.hs:1677-1686`).
5. Redeemers: three independent helpers (see below) producing
   `[(ConwayPlutusPurpose AsIx ConwayEra, (Data, ExUnits))]`.
6. `mkBasicTxBody` then lens-applies fields.
7. Script integrity hash recomputed from the assembled redeemer map
   (`TxBuild.hs:798-824`).

### Redeemer collectors — the body-order pattern

`collectSpendRedeemers` (`TxBuild.hs:1630-1643`): filters script-witnessed
spends; for each, `spendingIndex txIn allIns` (`TxBuild.hs:1605-1613`)
takes the position in `Set.toAscList allIns` — the same ascending order
the ledger applies. Emits
`(ConwaySpending (AsIx ix), (toLedgerData r, ExUnits 0 0))`.

`collectMintRedeemers` (`TxBuild.hs:1646-1675`): one redeemer per policy
ID; index is position in the sorted policy set
(`TxBuild.hs:1657-1663`). Emits `ConwayMinting (AsIx ix)`.

`collectWithdrawalRedeemers` (`TxBuild.hs:1688-1702`): script-only;
`withdrawalIndex` is position in `Map.keys` of the withdrawal map
(`TxBuild.hs:1615-1627`). Emits `ConwayRewarding (AsIx ix)`.

**Rule for the new collectors**: compute the `AsIx` against the same
ordered container the ledger applies to the body field, not against
raw DSL insertion order. In the pinned ledger API, `certsTxBodyL` is a
`StrictSeq` and `proposalProceduresTxBodyL` is an `OSet`; the spec
calls this out as the main risk (`spec.md:186-193`).

### Export list (`TxBuild.hs:21-90`)

Public symbols today: `spend`, `spendScript`, `reference`, `collateral`,
`payTo`, `payTo'`, `output`, `mint`, `withdraw`, `withdrawScript`,
`setMetadata`, `validFrom`, `validTo`, `setCollateralReturn`,
`requireSignature`, `attachScript`, `peek`, `valid`, `ctx`,
`checkMinUtxo`, `checkTxSize`, `draft`, `draftWith`, `build`,
`buildWith`, `BuildOptions`, `defaultBuildOptions`, `TxInstr`,
`Convergence`, `Check`, `LedgerCheck`, `Interpret`, `InterpretIO`,
`SpendWitness`, `MintWitness`, `WithdrawWitness`, `BuildError`.

The new exports follow the same naming style (`CertWitness`,
`ProposalWitness`, `certify`, `registerAndVoteAbstain`, `propose`,
`proposeTreasuryWithdrawal`) plus targeted ledger-type re-exports.

## 2. Test layout

### Unit / property tests — `TxBuildSpec`

`test/Cardano/Node/Client/TxBuildSpec.hs` (600+ lines). Hspec
property + unit style. Shared fixture helpers: `mkHash32`, `mkHash28`,
`mkTxIn`, `mkAddr`, `mkPolicyId`, `mkWitnessKeyHash`,
`mkRewardAccount`. The test-suite stanza is `tx-build-tests`
(`cardano-node-clients.cabal:306-338`).

`TxBuildSpec` is **not** listed under `other-modules:` in the cabal
stanza today — adding the new spec modules will need a cabal edit, but
it's not a blocker since the existing module is already discovered via
hs-source-dirs.

### Golden tests — `TxBuildGoldenSpec`

`test/Cardano/Node/Client/TxBuildGoldenSpec.hs` (400+ lines). Vectors
live under `test/fixtures/mainnet-txbuild/` as CBOR hex
(`{hash}.cbor.hex`, with paired `inputs/{hash}.inputs`). Decode pattern
(`TxBuildGoldenSpec.hs:170-184`):

```haskell
decodeFullAnnotatorFromHexText
    (natVersion @11)
    "mainnet golden tx"
    (decCBOR :: Decoder s (Annotator ConwayTx))
    hex
```

Comparison uses `assertStructurallyEquivalent expected actual`
(`TxBuildGoldenSpec.hs:141`). 14 mainnet vectors exist today (Minswap,
SundaeSwap, JPG Store, …).

For the new combinators we add vectors *generated from `cardano-cli`*
(per spec acceptance criteria 3 and 5), keyed by inputs the spec
fixes, stored next to the existing fixtures.

### E2E — `TxBuildSpec` (existing) and `TxBuildConwaySpec` (new)

`test/Cardano/Node/Client/E2E/TxBuildSpec.hs` (266 lines). Bootstraps a
devnet through `withDevnet` (the `setup.hs:205` helper), which in turn
calls the devnet library's `withCardanoNode`. N2C channels
(`LSQChannel`, `LTxSChannel`) come back from `withDevnet`, wrapped in
`provider` / `submitter` records. Submission goes through
`submitTx submitter signed → Submitted | Rejected`
(`E2E/TxBuildSpec.hs:213-219`). Ledger-state assertions are done by
querying through `provider` (e.g. `queryUTxOs provider addr`,
`waitForUtxos` polling at `E2E/TxBuildSpec.hs:241-257`).

`TxBuildConwaySpec` does **not yet exist**. The gate already
references it as the future Conway smoke target (see §4 below); the
test module is part of the work in this PR. The e2e test-suite stanza
is `e2e-tests` (`cardano-node-clients.cabal:340-366`); the new module
needs to be added under `other-modules:` there.

## 3. Conway ledger types

The DSL pins the era to `ConwayEra` and already imports several Conway
ledger symbols. The new code adds:

- `ConwayTxCert ConwayEra` — `Cardano.Ledger.Conway.TxCert`.
- `ProposalProcedure ConwayEra` and `Anchor`, `GovAction (..)`,
  `TreasuryWithdrawals` constructor — `Cardano.Ledger.Conway.Governance`
  (re-exported under `Cardano.Ledger.Conway` as well).
- `Credential 'Staking` — `Cardano.Ledger.Credential`.
- `RewardAccount` — `Cardano.Ledger.Address`.
- `ScriptHash`, `Coin`, `StrictMaybe` — already imported
  (`TxBuild.hs:163`, `:166`, `:180`).
- `DRep`'s `DRepAlwaysAbstain` constructor —
  `Cardano.Ledger.Conway.Core` / `Cardano.Ledger.Conway.Governance`.
- Lenses `certsTxBodyL`, `proposalProceduresTxBodyL` —
  `Cardano.Ledger.Conway.TxBody`.

The two new `ConwayPlutusPurpose` constructors used:

- `ConwayCertifying (AsIx i)`
- `ConwayProposing (AsIx i)`

The existing module already uses `ConwaySpending`, `ConwayMinting`,
`ConwayRewarding` from the same ADT, so the import path is settled.

The `tx-build` library's existing `build-depends` already include
`cardano-ledger-conway` and `cardano-ledger-api`
(`cardano-node-clients.cabal:39-65`), and so do the test stanzas
(`:306-338` and `:340-366`). No cabal dependency additions are
required for production code; the new test modules just need
`other-modules:` entries.

## 4. Quality gate

`llm/reviews/132/gate.sh` already exists (36 lines):

```bash
cabal build all -O0
cabal test cardano-node-clients:unit-tests -O0
cabal test cardano-node-clients:tx-build-tests -O0
fourmolu -m check
hlint
cabal-fmt -c cardano-node-clients.cabal

if [[ "${GATE_FULL:-0}" == "1" ]]; then
    cabal test cardano-node-clients:e2e-tests -O0 \
        --test-option=--match \
        --test-option='/Cardano.Node.Client.E2E.TxBuildConwaySpec/'
fi
```

Inner loop is always required. The boundary smoke gates behind
`GATE_FULL=1` and is required green before finalization
(`spec.md:240-242`).

## 5. Consumer reference

`amaru-treasury-tx#82` is the consumer; nothing in this repo vendors
it or pins it. The DSL contract is "produce a `ConwayTx` whose body
fields and redeemers match what the existing `cardano-cli conway
stake-address registration-and-vote-delegation-certificate
--always-abstain` and `cardano-cli conway governance action
create-treasury-withdrawal` calls emit". Golden vectors generated from
those CLI invocations are the contract test, see §6.

## 6. Decisions and alternatives

- **Decision**: Reuse the `Peek` mechanism for cert/proposal index
  resolution.
  **Why**: it's the same problem already solved for spend/mint/withdraw;
  any custom indexing would create a fourth pattern.
  **Alternative rejected**: returning the *insertion* index and
  documenting the mismatch — rejected because the redeemer indices the
  validator sees are body-field positions, and the existing API contract is
  "returned index is the one the validator sees".

- **Decision**: Two-tier API — a generic `certify` / `propose` plus a
  smart constructor for the one cert / proposal shape the consumer
  needs.
  **Why**: the generic form is necessary for golden testing arbitrary
  ledger fixtures and for downstream slices (#131, future actions); the
  smart constructor is what `amaru-treasury-tx#82` actually calls.
  **Alternative rejected**: ship only the smart constructors — rejected
  because the golden suite needs to feed arbitrary CBOR-equivalent
  certs and proposals to prove final body-field order.

- **Decision**: Golden vectors are generated from `cardano-cli` and
  stored as CBOR hex under `test/fixtures/mainnet-txbuild/conway-042/`.
  **Why**: the spec's acceptance criteria 3 and 5 require structural
  equality with the CLI's output; matching the existing fixture layout
  keeps the test infrastructure unchanged.
  **Alternative rejected**: hand-rolled expected CBOR — rejected
  because round-tripping through `cardano-cli` is the actual
  compatibility contract.

- **Decision**: Boundary smoke asserts the `DRepAlwaysAbstain`
  delegation state through the existing `LocalStateQuery` channel.
  **Why**: same pattern the existing E2E test uses; no new query
  primitive needed.
  **Alternative rejected**: parse devnet log output — rejected on
  reliability grounds; LSQ is the typed interface.

- **Decision**: proposal redeemers model guardrail scripts, not a
  proposer credential. Hoogle and the pinned ledger source show
  `ConwayProposing` is needed only when `getProposalScriptHash` finds a
  guardrail script hash in the governance action. The first consumer
  passes `SNothing` and `NoProposalScript`; guardrail coverage is still
  property-tested through generic `propose`.

## 7. Risks (research-confirmed)

- **Index drift**: confirmed live risk. `certsTxBodyL` and
  `proposalProceduresTxBodyL` have ledger-defined body container order.
  The `Peek` + body-order collector pattern (same as the three existing
  ones) eliminates the gap.
- **Conway TxCert ADT shape**: pinned via `cabal.project` + CHaP; out
  of scope to bump.
- **Anchor metadata hash**: caller-supplied `SafeHash`. DSL does not
  fetch.
- **Guardrail scripts**: `proposeTreasuryWithdrawal` exposes
  `StrictMaybe ScriptHash` for the guardrail; first consumer passes
  `SNothing`. Generic `propose` accepts any `ProposalProcedure`, so the
  guardrail-bearing path is reachable without further work.
