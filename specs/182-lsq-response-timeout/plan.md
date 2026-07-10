# Plan: bounded LocalStateQuery responses

## Technical context

- Language: Haskell, GHC 9.12.3, `GHC2021`
- Concurrency: STM plus `async`
- Protocol test: `typed-protocols:stateful` direct peer connector
- Verification: Hspec unit test and `nix develop --quiet -c just ci`

## Design

Extend `LSQChannel` with a response timeout and an STM liveness generation.
Every request snapshots the generation in the same transaction that enqueues
it. Waiting selects among result delivery, generation invalidation, and the
request deadline. The first deadline advances the generation and throws
`LocalStateQueryTimeout`; existing sibling waiters observe the generation
change and throw `ConnectionLost`.

Wrap the enclosing N2C connection action in a liveness monitor. It snapshots
the current generation, runs the connection on its calling thread, and starts
only the generation watcher as a child. If a request times out, the watcher
interrupts the connection caller with the typed timeout. A reconnect snapshots
the new generation and is not poisoned by the historical signal.

## Slice 1: regression and liveness fix

One vertical, bisect-safe commit:

1. Add a direct typed-protocol mock server that accepts an LSQ query and never
   replies; run it against the real channel-driven client.
2. Observe RED on current `main`: the query reaches the test's outer deadline.
3. Add the typed exception, configurable/default channel timeout, generation
   wait logic, and connection monitor.
4. Wire both connection constructors through the monitor.
5. Assert the first timeout, sibling wake-up, and connection termination; run
   focused GREEN, red-green revert/restore proof, then the full gate.

## Live-boundary correction

The node-free typed-protocol test proved timeout propagation but bypassed the
real Ouroboros mux boundary. In CI, the healthy devnet forged continuously
while the readiness probe connected, waited five seconds, and closed with a
broken pipe on every attempt. The implementation commit had enabled the
threaded RTS for unit tests because STM `registerDelay` requires it, but omitted
the same runtime option from the E2E executable.

Keep the generation invalidation semantics and the original manual stateful
LSQ callback, but monitor the enclosing `connectTo` action. The connection must
remain on its calling thread; a child generation watcher interrupts that caller
on timeout. The whole mux connection then unwinds as the lifecycle unit already
owned by the reconnect supervisor. Run E2E with `-threaded`, matching the unit
suite and every production executable that consumes these deadlines.

## Slice 2: live connection regression correction

One bisect-safe correction commit:

1. Use the existing devnet E2E suite as the live-boundary RED; bound the command
   externally so the regression fails instead of occupying a runner forever.
2. Restore the original manual stateful LSQ callback in both N2C applications.
3. Run each enclosing N2C connection on its caller while a child generation
   watcher interrupts that caller on invalidation.
4. Assert timeout, sibling wake-up, connection termination, caller-thread
   identity, and fresh-generation recovery in the node-free regression.
5. Enable the threaded RTS for E2E, run live devnet GREEN, and run the exact
   aggregate Nix build used by GitHub CI.

## Files

- `lib/Cardano/Node/Client/N2C/Types.hs`
- `lib/Cardano/Node/Client/N2C/LocalStateQuery.hs`
- `lib/Cardano/Node/Client/N2C/Connection.hs`
- `test/Cardano/Node/Client/N2C/LocalStateQuerySpec.hs`
- `test/unit-main.hs`
- `cardano-node-clients.cabal`

Slice 2 changes the three N2C implementation/test modules plus the E2E test
stanza in `cardano-node-clients.cabal`; no devnet fixture changes are needed.

## Compatibility and risk

`newLSQChannel` and all query helpers keep their existing types. The new
constructor is additive. The principal risk is a false timeout for unusually
slow ledger evaluation; the 60-second default matches the downstream mitigation
that exposed the bug, while the additive constructor permits an explicit
application budget.
