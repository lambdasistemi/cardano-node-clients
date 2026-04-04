# Tasks: Chain Populator

## Task 1: Define ChainPopulator type and populateChain signature

Create `e2e-test/Cardano/Node/Client/E2E/ChainPopulator.hs` with the `ChainPopulator` newtype and `populateChain` type signature (stub implementation).

**Dependencies**: None

---

## Task 2: Implement populateChain wiring

Wire LSQ + LTxS + ChainSync connections. Build the Follower that calls onSlot, signs, submits, accumulates blocks. Use TMVar for done signal.

**Dependencies**: Task 1

---

## Task 3: Export from devnet library

Add `ChainPopulator` module to the devnet library stanza in the cabal file. Add necessary dependencies.

**Dependencies**: Task 2

---

## Task 4: E2E test

Write a test that uses a simple populator (submit one self-transfer on first slot with UTxOs) and verifies the transaction appears in the returned blocks.

**Dependencies**: Task 3
