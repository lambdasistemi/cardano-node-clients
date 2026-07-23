# Technical Plan — Issue 187: Devnet PV11 & Full PlutusV3 Cost Model

## Tech Stack & Architecture

- **Language & Harness**: Haskell (`cardano-node-clients:e2e-test`)
- **Ledger/Node API**: `cardano-ledger-api` / `cardano-ledger-conway`, N2C LocalStateQuery & LocalTxSubmission.
- **Node Pin**: `cardano-node` 11.0.1 (pinned in `flake.nix`).

## Slices

### Slice A — Provenance Fixture & Configuration Options
- Create `e2e-test/fixtures/pparams-pv11-mainnet.json` with 350-entry PlutusV3 cost model and provenance timestamp/source metadata.
- Export `DevnetConfig`, `TargetPV (PV10 | PV11)`, `defaultDevnetConfig`, and `withDevnetConfig` in `Cardano.Node.Client.E2E.Setup`.

### Slice B — Intra-Conway Governance Transition
- Update `e2e-test/genesis/conway-genesis.json` and `shelley-genesis.json` (or patch during `prepareTmpDir`) to set up initial genesis governance keys (Constitutional Committee and SPO delegate) and slot parameters.
- Implement `transitionDevnetToPV11` in `Cardano.Node.Client.E2E.Devnet` / `Setup.hs`:
  1. Build governance transaction containing `HardForkInitiation` (major = 11) and `ParameterChange` (PlutusV3 cost model length = 350).
  2. Vote and sign with genesis governance keys.
  3. Submit transaction and wait for epoch transition enactment.

### Slice C — Harness Verification & Test Suite
- Add post-init assertion in `withDevnetConfig` verifying `protocolVersion.major == 11` and `PlutusV3` cost model length == 350.
- Add test coverage in `e2e-test` suite verifying PV11 devnet initialization and execution of transactions using Plomin-era builtins.
