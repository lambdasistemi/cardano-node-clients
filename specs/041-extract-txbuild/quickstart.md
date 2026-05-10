# Quickstart: Extract TxBuild

## Build The Extracted Component

```bash
cabal build lib:tx-build -O0
```

## Run Focused Transaction-Builder Tests

```bash
cabal test cardano-node-clients:unit-tests -O0 --test-options='--match "/TxBuild/"'
cabal test cardano-node-clients:unit-tests -O0 --test-options='--match "/balanceTx/"'
```

If a dedicated tx-build test suite is added during implementation, run:

```bash
cabal test cardano-node-clients:tx-build-tests -O0 --test-show-details=direct
```

## Check The Dependency Boundary

```bash
./scripts/check-tx-build-boundary.sh
```

The command must fail if the extracted component depends on N2C,
ouroboros network protocols, chain-follower, socket-server, indexer, or
RocksDB packages.

## Validate Compatibility

```bash
just unit
cabal build cardano-node-clients -O0
cabal build cardano-node-clients:cardano-tx-generator -O0
```

These commands prove that existing imports through the main package still
compile while the implementation lives in the extracted component.
