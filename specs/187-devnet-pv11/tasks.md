# Tasks — Issue 187: Devnet PV11 & Full PlutusV3 Cost Model

## Slice A — Provenance Fixture & Configuration Options
- [ ] T187-SA1 Create provenance-stamped fixture `e2e-test/fixtures/pparams-pv11-mainnet.json` containing 350-entry PlutusV3 cost model and PV11 parameters.
- [ ] T187-SA2 Add `DevnetConfig`, `TargetPV`, and `withDevnetConfig` to `Cardano.Node.Client.E2E.Setup`.
- [ ] T187-SA3 Verify builds and slice A commit.

## Slice B — Governance Transition Mechanism
- [ ] T187-SB1 Configure genesis governance keys (CC and SPO) and patch genesis start/epoch parameters in `Devnet.hs`.
- [ ] T187-SB2 Implement governance transaction creation and submission for `HardForkInitiation` (PV 11) and `ParameterChange` (PlutusV3 350 cost model).
- [ ] T187-SB3 Verify governance enactment during harness init and slice B commit.

## Slice C — Verification & E2E Test Suite
- [ ] T187-SC1 Implement post-init assertions (`protocolVersion.major == 11` and `length PlutusV3 == 350`) in `Setup.hs`.
- [ ] T187-SC2 Add E2E tests for PV11 devnet setup and Plomin-era builtin script execution.
- [ ] T187-SC3 Verify entire test suite (`just ci` / `cabal test`) and slice C commit.
