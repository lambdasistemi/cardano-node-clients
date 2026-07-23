# Spec 187: Protocol Version 11 and Full PlutusV3 Cost Model Support in Devnet

## User Story

As a developer testing Cardano smart contracts against a local devnet using `cardano-node-clients`,
I want the `withDevnet` test harness to support bringing the devnet to Protocol Version 11 with the full 350-entry PlutusV3 cost model via intra-Conway governance actions,
So that downstream applications (such as `cardano-keri`) can execute transactions using Plomin-era PlutusV3 builtins under production pricing and protocol parameters without private workarounds.

## Functional Requirements

- **FR-1 (Opt-in Configuration)**: `withDevnet` MUST support an opt-in configuration (`DevnetConfig` / `withDevnetConfig`) allowing users to request a `PV11` devnet. Default `withDevnet` behavior MUST remain `PV10` for backwards compatibility.
- **FR-2 (Intra-Conway Governance Transition)**: When `PV11` is selected, during harness init the harness MUST execute an intra-Conway governance transition:
  1. Submit a `HardForkInitiation` governance action bumping `protocolVersion.major` from 10 to 11.
  2. Submit a `ParameterChange` governance action updating the `PlutusV3` cost model to the full 350-entry production cost model (and setting production execution limits 16.5M memory / 10B steps).
  3. Sign and vote on the governance proposals using the devnet's genesis governance key arrangement so the actions are enacted.
- **FR-3 (Post-Init Verification)**: Harness init MUST query protocol parameters post-transition and assert:
  - `protocolVersion.major == 11`
  - `PlutusV3` cost model entry count == 350
  - Ledger era remains Conway.
  If assertions fail, harness init MUST raise an informative error.
- **FR-4 (Parameter Provenance)**: The 350-entry PlutusV3 cost model and PV11 parameters MUST be sourced from a committed, provenance-stamped fixture file (`e2e-test/fixtures/pparams-pv11-mainnet.json`).

## Success Criteria

1. Running `withDevnetConfig (defaultDevnetConfig { devnetTargetPV = PV11 })` successfully initializes a node running at PV11 with 350 PlutusV3 cost model entries.
2. Transactions using Plomin-era builtins evaluate and settle successfully on the PV11 devnet.
3. All unit and E2E test suites pass cleanly.
