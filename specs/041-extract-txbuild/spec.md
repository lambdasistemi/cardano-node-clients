# Feature Specification: Extract TxBuild

**Feature Branch**: `041-extract-txbuild`  
**Created**: 2026-05-10  
**Status**: Draft  
**Input**: User description: "Extract TxBuild from cardano-node-clients into a standalone non-network transaction-building library while preserving existing users and keeping N2C, consensus, indexer, daemon, socket, and RocksDB dependencies out of the extracted surface."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Use TxBuild Without Node Clients (Priority: P1)

A downstream transaction author can depend on the transaction-building
surface without also pulling in node communication, chain following,
indexer persistence, daemons, socket servers, or devnet support.

**Why this priority**: This is the core value of the extraction. It
turns TxBuild into a reusable off-chain construction tool instead of a
feature hidden inside a broader node-client package.

**Independent Test**: A minimal downstream fixture depends only on the
transaction-building surface, builds a simple Conway-era transaction,
and its dependency graph does not include node networking, socket,
chain-follower, indexer, or RocksDB components.

**Acceptance Scenarios**:

1. **Given** a downstream project that only needs to construct and
   balance transactions, **When** it depends on the extracted surface,
   **Then** it can use TxBuild and balancing features without depending
   on node-client communication features.
2. **Given** the extracted surface is inspected, **When** its dependency
   boundary is checked, **Then** network, consensus-block following,
   socket server, daemon, indexer storage, and RocksDB dependencies are
   absent from that surface.

---

### User Story 2 - Existing Users Keep Working (Priority: P2)

An existing cardano-node-clients user can upgrade without rewriting
transaction-building imports or changing the way node-client features
are consumed.

**Why this priority**: The extraction should reduce coupling without
turning into a breaking migration for current users.

**Independent Test**: Existing transaction-builder unit tests, golden
tests, tx-generator build helpers, and public imports compile through
the current cardano-node-clients package after the extraction.

**Acceptance Scenarios**:

1. **Given** an existing user imports TxBuild through the current
   package, **When** the package is rebuilt, **Then** the import still
   resolves and exposes the same supported behavior.
2. **Given** cardano-node-clients uses TxBuild internally, **When** the
   tx-generator and E2E test components are built, **Then** they use the
   extracted surface without duplicate implementations.

---

### User Story 3 - Maintainers Can Enforce The Boundary (Priority: P3)

A maintainer can tell which components belong to the extracted
transaction-building surface and can prevent network or indexer
dependencies from creeping back into it.

**Why this priority**: The feature only stays useful if the boundary is
explicit, documented, and mechanically checked.

**Independent Test**: Documentation names the allowed and excluded
surfaces, and a verification command fails if forbidden dependency names
appear in the extracted transaction-building component.

**Acceptance Scenarios**:

1. **Given** a contributor adds a new dependency to the extracted
   surface, **When** the boundary verification is run, **Then** forbidden
   network, daemon, indexer, or RocksDB dependencies are rejected.
2. **Given** a downstream user reads the documentation, **When** they
   need transaction building only, **Then** the docs point them at the
   extracted surface and explain which broader node-client pieces are
   intentionally outside it.

### Edge Cases

- The transaction builder needs a script evaluator, but the evaluator
  should be supplied by the caller rather than forcing a node-client
  provider dependency.
- Mainnet golden vector fixtures must continue proving real transaction
  structure coverage after the extraction.
- Existing cardano-node-clients users must not accidentally get two
  divergent TxBuild implementations.
- A future contributor may add a convenience function that imports node
  communication or indexer modules; the feature must make that boundary
  violation visible.
- The extracted surface should not claim to be a full wallet, node
  client, coin-selection engine, or UTxO indexer.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST provide a transaction-building surface
  that can be consumed independently from node communication features.
- **FR-002**: The extracted surface MUST include the supported TxBuild
  DSL behavior, transaction balancing behavior, script-integrity helper
  behavior, execution-unit placeholder behavior, and the Conway
  transaction type needed by those features.
- **FR-003**: The extracted surface MUST NOT require N2C clients, chain
  follower integration, consensus block extraction, UTxO indexer
  persistence, daemon control wires, socket servers, devnet fixtures, or
  RocksDB storage.
- **FR-004**: Existing cardano-node-clients users MUST retain a
  compatibility path for the current transaction-building module names.
- **FR-005**: Existing transaction-building behavior MUST remain covered
  by unit tests and mainnet golden vector tests after the extraction.
- **FR-006**: The build flow MUST allow callers to supply their own
  script-evaluation function without depending on the node-client
  provider implementation.
- **FR-007**: Documentation MUST state what belongs to the extracted
  transaction-building surface and what intentionally remains in the
  broader node-client package.
- **FR-008**: Verification MUST include a dependency-boundary check that
  detects forbidden network, daemon, indexer, or RocksDB dependencies in
  the extracted surface.
- **FR-009**: The broader cardano-node-clients package MUST consume the
  extracted surface rather than maintaining a forked copy of the same
  behavior.

### Key Entities

- **Transaction-Building Surface**: The reusable capability for
  describing, assembling, evaluating through a caller-supplied
  evaluator, and balancing Conway-era transactions.
- **Node-Client Surface**: The broader set of node communication,
  submission, local state query, chain sync, reconnection, devnet,
  tx-generator daemon, and indexer features that remain outside the
  extracted surface.
- **Compatibility Path**: The public route that lets existing
  cardano-node-clients users keep using current transaction-building
  module names while the implementation lives behind the new boundary.
- **Boundary Verification**: The check that proves the extracted surface
  has not acquired forbidden dependencies.
- **Regression Suite**: The unit, golden, and focused integration
  coverage that proves extraction did not change transaction-building
  behavior.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A minimal transaction-building build target succeeds
  without listing any forbidden network, chain-follower, indexer, socket,
  daemon, or RocksDB dependencies.
- **SC-002**: Existing TxBuild unit tests and mainnet golden vector tests
  pass against the extracted surface.
- **SC-003**: Existing cardano-node-clients build and focused tests still
  compile through the compatibility path.
- **SC-004**: Documentation identifies the extracted surface, the
  compatibility path, and the excluded broader node-client features.
- **SC-005**: Boundary verification fails when a forbidden dependency is
  added to the extracted surface and passes with the intended dependency
  set.

## Assumptions

- The first delivery extracts the library boundary inside this
  repository; publishing or moving to a separate repository can follow
  after the boundary is proven.
- The extracted surface remains Conway-era focused, matching the current
  TxBuild implementation.
- Script evaluation remains caller-supplied for the extracted builder.
  Live node-backed evaluation stays in the broader node-client surface.
- Existing transaction-builder behavior is the compatibility baseline;
  this feature is not intended to redesign the DSL.
