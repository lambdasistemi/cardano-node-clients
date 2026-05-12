# 042 — Quickstart

How `amaru-treasury-tx#82` switches from `cardano-cli` to the TxBuild
DSL once this PR lands.

## Before — shell-out

The current smoke harness in `amaru-treasury-tx` shells out twice
before the Amaru-side flow runs:

```sh
cardano-cli conway stake-address \
    registration-and-vote-delegation-certificate \
    --stake-script-file stake.script \
    --always-abstain \
    --key-reg-deposit-amt "$DEPOSIT" \
    --out-file register-abstain.cert

cardano-cli conway governance action create-treasury-withdrawal \
    --governance-action-deposit "$PROP_DEPOSIT" \
    --deposit-return-stake-script-file return.script \
    --anchor-url "$ANCHOR_URL" \
    --anchor-data-hash "$ANCHOR_HASH" \
    --funds-receiving-stake-address "$PAYEE" \
    --transfer "$AMOUNT" \
    --out-file treasury-withdrawal.action
```

These two artifacts are then fed to `cardano-cli conway transaction
build / sign / submit`, which is the `cardano-cli` boundary the spec
wants to retire.

## After — typed DSL

```haskell
import Cardano.Node.Client.TxBuild

setupTx
    :: Credential 'Staking
    -> Coin
    -> Coin
    -> RewardAccount
    -> Anchor
    -> RewardAccount
    -> Coin
    -> StakeRedeemer
    -> TxBuild q e ()
setupTx
    stakeCred
    keyDeposit
    proposalDeposit
    returnAccount
    anchor
    payeeAccount
    payeeAmount
    stakeRedeemer = do
        -- existing TxBuild calls for inputs / outputs / scripts
        attachScript stakeScript
        _ <- registerAndVoteAbstain
                stakeCred
                keyDeposit
                (ScriptCert stakeRedeemer)
        _ <- proposeTreasuryWithdrawal
                proposalDeposit
                returnAccount
                anchor
                (Map.singleton payeeAccount payeeAmount)
                SNothing
                NoProposalScript
        pure ()
```

The `Word32` returns are discarded here because nothing downstream
references the cert / proposal indices from inside a redeemer. The
treasury-withdrawal proposal shown here has no guardrail script, so it
does not carry a `ConwayProposing` redeemer. If a later consumer uses
`SJust guardrailHash`, it must attach the guardrail script and pass
`GuardrailProposal redeemer`.

The DSL pipeline then runs the existing balance / ExUnits loop and
returns a `ConwayTx` ready for the existing
`Cardano.Node.Client.LocalTxSubmission` submission path. No
`cardano-cli` is needed at any step.

## Golden-vector regeneration

Each acceptance-criteria golden vector pairs with an exact
`cardano-cli` invocation so reviewers can reproduce it. The fixtures
are certificate/proposal artifacts, not full transactions. Golden tests
decode the artifact CBOR and compare it with the corresponding body
field emitted by the DSL. For the register-and-vote-abstain cert:

```sh
cardano-cli conway stake-address \
    registration-and-vote-delegation-certificate \
    --stake-script-file <fixed-script.plutus> \
    --always-abstain \
    --key-reg-deposit-amt 2000000 \
    --out-file /tmp/cert.json

# Extract the CBOR and hex-encode for the golden fixture.
jq -r '.cborHex' /tmp/cert.json \
    > test/fixtures/mainnet-txbuild/conway-042/register-and-vote-abstain.cbor.hex
```

Treasury-withdrawal proposal:

```sh
cardano-cli conway governance action create-treasury-withdrawal \
    --testnet \
    --governance-action-deposit 100000000 \
    --deposit-return-stake-script-file <fixed-return.plutus> \
    --anchor-url "https://example.invalid/anchor.json" \
    --anchor-data-hash <fixed-hash> \
    --funds-receiving-stake-script-file <fixed-payee.plutus> \
    --transfer 1000000 \
    --out-file /tmp/action.json

jq -r '.cborHex' /tmp/action.json \
    > test/fixtures/mainnet-txbuild/conway-042/treasury-withdrawal.cbor.hex
```

The exact script bytes used for these golden vectors are checked in
under the same directory so the regeneration is fully deterministic.

## Boundary smoke (`GATE_FULL=1`)

`Cardano.Node.Client.E2E.TxBuildConwaySpec` runs against the existing
short-epoch devnet:

1. Boot devnet via the existing `withDevnet` helper.
2. Submit a tx that calls `registerAndVoteAbstain` for a script stake
   credential. Wait for inclusion.
3. Query the live ledger state via `LSQ`; assert the credential is
   registered with `DRepAlwaysAbstain` as its delegated DRep.
4. Submit a second tx with `proposeTreasuryWithdrawal`. Wait for
   inclusion.
5. Query the proposals snapshot; assert the new proposal procedure is
   present with the exact payee map, deposit-return account, anchor,
   and `SNothing` guardrail.

The smoke is required green before finalization; the inner loop runs
without it for tight iteration.

## Manual sanity (post-merge, optional)

After merge, the `amaru-treasury-tx#82` PR opens against this DSL
version. The consumer test there replaces both `cardano-cli`
invocations with the snippet at the top of this file. No protocol
change is needed on the consumer side beyond a CHaP / source-rep bump
of `cardano-node-clients`.
