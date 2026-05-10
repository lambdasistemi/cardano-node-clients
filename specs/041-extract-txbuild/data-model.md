# Data Model: Extract TxBuild

## Transaction-Building Component

Represents the extracted library surface.

Fields:

- Public modules: transaction DSL, balancing helpers, Conway transaction
  alias.
- Allowed dependencies: ledger, Plutus data/ex-units, serialization,
  containers, operational monad, lenses, slotting.
- Forbidden dependencies: N2C, ouroboros network protocols,
  chain-follower, consensus block extraction, socket server, tx-generator
  daemon, UTxO indexer storage, RocksDB.

Validation rules:

- Must build independently.
- Must not depend on forbidden packages or internal modules.
- Must expose all behavior required by existing TxBuild and Balance
  tests.

## Main Node-Client Component

Represents the existing broad package surface.

Fields:

- N2C client modules.
- Provider and submitter abstractions.
- Provider-backed evaluation helper.
- Tx-generator daemon and control server.
- UTxO indexer integration.
- Compatibility wrappers for transaction-building modules.

Validation rules:

- Must continue compiling existing imports.
- Must consume the extracted component rather than duplicate it.
- May depend on network and indexer packages.

## Compatibility Wrapper

Represents a module that preserves an existing public import path.

Fields:

- Existing module name.
- Re-exported implementation module.
- Export list matching current public behavior.

Validation rules:

- Must not contain a forked implementation.
- Must keep downstream source compatibility for supported exports.

## Boundary Check

Represents the verification that protects the extracted component.

Fields:

- Allowed component name.
- Forbidden dependency names.
- Command used during local verification.

Validation rules:

- Passes for the intended extracted component.
- Fails when a forbidden dependency is added to that component.

## Regression Suite

Represents the behavior-preservation evidence.

Fields:

- Balance unit tests.
- TxBuild unit tests.
- Mainnet TxBuild golden vectors.
- Existing main-library compile and focused tests.

Validation rules:

- Tests must exercise the extracted implementation.
- Golden vectors must continue comparing reconstructed transaction
  structure against committed fixtures.
