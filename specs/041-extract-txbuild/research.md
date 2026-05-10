# Research: Extract TxBuild

## Decision: Extract TxBuild With Balance And ConwayTx Alias

**Rationale**: `Cardano.Node.Client.TxBuild` imports
`Cardano.Node.Client.Balance` for balancing, script-integrity hashing,
reference-script fee accounting, and execution-unit helpers. Both
modules share the `ConwayTx` alias. Extracting only TxBuild would either
leave cross-component imports behind or create duplicate helper code.

**Alternatives considered**:

- Extract TxBuild alone: rejected because it would keep a dependency on
  the main library's Balance module.
- Extract the entire main library: rejected because it carries N2C,
  consensus, tx-generator, indexer, and socket dependencies.

## Decision: First Use A Public Cabal Sublibrary

**Rationale**: A public sublibrary proves the boundary inside the
current repository, reduces migration risk, and lets downstream projects
depend on the transaction-building surface without building the main
node-client library. It also avoids an immediate publishing or repository
split.

**Alternatives considered**:

- New repository immediately: cleaner long-term, but too large for the
  first boundary proof.
- Keep everything in the main library and only document imports:
  rejected because consumers would still inherit the broad component
  dependency set.

## Decision: Keep Evaluate Outside Initial Extraction

**Rationale**: `Evaluate` depends on the provider abstraction, while
`TxBuild.build` already accepts an evaluator callback. The initial
extracted component can support script-bearing transactions without
owning a provider or live node abstraction.

**Alternatives considered**:

- Move `Evaluate` now: rejected because it expands the extracted surface
  from transaction construction into chain-query abstractions.
- Duplicate evaluation logic: rejected because it would create two
  places to maintain ExUnits patching and balancing behavior.

## Decision: Preserve Current Module Names Through Wrappers

**Rationale**: Existing downstreams and in-repo modules import
`Cardano.Node.Client.TxBuild` and `Cardano.Node.Client.Balance`. Wrapper
modules in the main library can preserve those imports while delegating
the implementation to the extracted component.

**Alternatives considered**:

- Rename modules immediately: rejected because it turns a dependency
  cleanup into a migration event.
- Keep implementation in both places: rejected because behavior would
  diverge.

## Decision: Add A Dependency Boundary Check

**Rationale**: The feature's value depends on keeping network, daemon,
indexer, and storage dependencies out of the extracted surface. A check
over the cabal stanza catches accidental regressions before review.

**Alternatives considered**:

- Rely on reviewer discipline: rejected because dependency creep is easy
  to miss in a large Cabal file.
- Depend only on build failures: rejected because broad dependencies may
  still compile while defeating the extraction goal.
