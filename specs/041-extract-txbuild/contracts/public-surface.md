# Contract: Extracted TxBuild Public Surface

## Purpose

The transaction-building component is a non-network library surface for
constructing and balancing Conway-era transactions. It must be usable
without the broader cardano-node-clients N2C, indexer, daemon, devnet,
or socket-server features.

## Owned Surface

The extracted component owns these public capabilities:

- TxBuild program type and instruction GADT.
- Smart constructors for spends, script spends, reference inputs,
  collateral, outputs, inline datums, minting, withdrawals, metadata,
  required signatures, attached scripts, and validity intervals.
- Deferred `peek`, `ctx`, and `valid` instructions.
- Pure draft assembly.
- Effectful build flow that accepts a caller-supplied evaluator.
- Transaction balancing helpers.
- Script-integrity, spending-index, reference-script-size, and
  execution-unit helper behavior.
- Conway transaction alias used by the above APIs.

## Explicitly Excluded Surface

The extracted component must not own:

- N2C connection, local state query, local tx submission, chain sync, or
  reconnect logic.
- Provider-backed live node evaluation.
- Submitter implementations.
- Devnet setup.
- Tx-generator daemon or control socket server.
- UTxO indexer daemon, block extraction, storage, or server.
- Consensus block aliases or block points.
- RocksDB-backed persistence.

## Compatibility Contract

The main cardano-node-clients library must continue exposing the current
transaction-building module names as compatibility re-exports. Existing
users should be able to keep importing the old module names while new
dependency-minimal users can depend on the extracted component.

## Boundary Contract

The extracted component must reject direct dependencies whose names match
these families:

- `cardano-diffusion`
- `chain-follower`
- `contra-tracer`
- `network`
- `network-mux`
- `ouroboros-consensus`
- `ouroboros-network`
- `rocksdb`
- `typed-protocols`
- `unix` when introduced solely for sockets or daemons

Ledger packages, Plutus packages, serialization, containers,
microlens, operational, bytestring, and cardano-slotting are allowed
when required by TxBuild or Balance behavior.
