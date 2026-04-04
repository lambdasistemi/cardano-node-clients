# Feature Specification: Deterministic Chain Populator

**Feature Branch**: `001-chain-populator`
**Created**: 2026-04-02
**Status**: Draft
**Input**: GitHub issue #28

## User Scenarios & Testing

### User Story 1 - Populate a devnet with known transactions (Priority: P1)

A test author provides a CPS state machine that, given the current slot and UTxO set, returns transactions to submit and a continuation. The infrastructure runs this against a devnet, submits the transactions, and returns the resulting chain (all blocks).

**Why this priority**: Without this, E2E tests cannot produce deterministic chains. Transaction timing is unpredictable, making state comparisons unreliable.

**Independent Test**: Provide a populator that submits one self-transfer at the first slot with UTxOs. Verify the returned chain contains a block with that transaction.

**Acceptance Scenarios**:

1. **Given** a populator that submits a tx at the first slot with UTxOs, **When** `populateChain` runs, **Then** the returned blocks contain the transaction in a subsequent block.
2. **Given** a populator that returns `Nothing` after submitting, **When** `populateChain` runs, **Then** it returns with all blocks up to that point.
3. **Given** a populator that submits 3 txs at different slots, **When** `populateChain` runs, **Then** the returned blocks contain all 3 transactions in separate blocks.

---

### User Story 2 - Populator receives fresh UTxO set per slot (Priority: P1)

Each invocation of the populator's `onSlot` receives the current UTxO set at the address, so it can build valid transactions using available inputs.

**Why this priority**: Transactions must reference existing UTxOs. After each submission, the UTxO set changes (spent input, new change output).

**Acceptance Scenarios**:

1. **Given** a populator that submits a tx spending UTxO A, **When** the next slot arrives, **Then** `onSlot` receives a UTxO set without A but with the change output.

---

### Edge Cases

- Populator returns empty transaction list — no submission, just advance
- Transaction gets rejected by the node — should be reported, not silently dropped
- Populator signals done (`Nothing`) — stop following and return blocks

## Requirements

### Functional Requirements

- **FR-001**: The populator MUST be a CPS state machine: `onSlot :: SlotNo -> [(TxIn, TxOut)] -> IO ([Tx ConwayEra], Maybe ChainPopulator)`
- **FR-002**: `populateChain` MUST return the full list of blocks received from ChainSync
- **FR-003**: Transactions returned by the populator MUST be signed (by the caller or the infrastructure) and submitted via the Submitter
- **FR-004**: The UTxO set passed to `onSlot` MUST be queried fresh via LSQ at the current chain tip
- **FR-005**: When the populator returns `Nothing`, the function MUST stop and return the accumulated blocks

### Key Entities

- **ChainPopulator**: CPS state machine that decides what to submit at each slot
- **Block**: `CardanoBlock StandardCrypto` — the real Cardano block from ChainSync
- **populateChain**: The runner function that wires ChainSync + LSQ + Submitter

## Success Criteria

- **SC-001**: E2E test: populator submits 3 txs, all appear in returned blocks
- **SC-002**: `just ci` green
- **SC-003**: Lives in the devnet library, usable by downstream packages

## Assumptions

- The caller provides the signing key and address
- The devnet produces blocks every ~1 second
- The populator builds unsigned transactions; the infrastructure signs them
