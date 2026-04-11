# WIP: Transaction Builder DSL

## Status
Slices 1-4 done, unit tests green. Next: Slice 5 (Valid).

## Links
- PR: lambdasistemi/cardano-node-clients#38
- Issue: lambdasistemi/cardano-node-clients#36
- Branch: `003-tx-builder-dsl`
- Worktree: `/code/cardano-node-clients-tx-builder`

## Done

### Slice 1: Simple spend + draft
- `TxInstr q e a` GADT with `Spend`, `Send`, `Collateral`, `Peek`
- `Convergence a = Iterate a | Ok a`
- `spend` returns `Word32` via `Peek`, `payTo`, `collateral`
- `draft` interpreter (two-pass, pure)
- `Interpret`/`InterpretIO` newtypes

### Slice 2: Script spend + mint + redeemer indices
- `ScriptWitness` existential, `MintWitness`
- `spendScript`, `mint`, `payTo'`, `attachScript`, `requireSignature`
- Auto redeemer index computation (spending + minting)
- Script integrity hash, script witnesses

### Slice 3: Build loop + Peek convergence
- `build` interpreter: iterate Peek, evaluate scripts, patch ExUnits, balance
- `BuildError e` type
- Convergence: all Peek Ok + Tx body stable

### Slice 4: Ctx + pluggable queries
- `Ctx :: q a -> TxInstr q e a`
- `ctx` smart constructor
- `draftWith :: PParams ConwayEra -> Interpret q -> TxBuild q e a -> Tx ConwayEra`
- `build` now takes `InterpretIO q`
- Test query GADT coverage in `TxBuildSpec`

## Next

### Slice 5: Valid + library checkers
### Slice 6: Reference inputs + validity intervals
### Slices 7-9: MPFS migrations

## Tests
18 `TxBuild` examples passing

## Key files
- `lib/Cardano/Node/Client/TxBuild.hs`
- `test/Cardano/Node/Client/TxBuildSpec.hs`
- `specs/003-tx-builder-dsl/spec-design.md`
- `specs/003-tx-builder-dsl/tasks.md`
