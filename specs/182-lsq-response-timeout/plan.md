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

Wrap the actual LSQ peer action in a liveness monitor. It snapshots the current
generation when the peer starts and races the peer against a generation change.
If a request times out, the monitor cancels the blocked peer and rethrows the
typed timeout. A reconnect starts from the new generation and is not poisoned
by the historical signal.

## Slice 1: regression and liveness fix

One vertical, bisect-safe commit:

1. Add a direct typed-protocol mock server that accepts an LSQ query and never
   replies; run it against the real channel-driven client.
2. Observe RED on current `main`: the query reaches the test's outer deadline.
3. Add the typed exception, configurable/default channel timeout, generation
   wait logic, and peer monitor.
4. Wire both connection constructors through the monitor.
5. Assert the first timeout, sibling wake-up, and peer termination; run focused
   GREEN, red-green revert/restore proof, then the full gate.

## Live-boundary correction

The node-free typed-protocol test proved timeout propagation but bypassed the
real Ouroboros mux boundary. In CI, wrapping the individual LSQ mini-protocol
callback in the generation race prevented a usable LSQ exchange: the healthy
devnet forged continuously while the readiness probe connected, waited five
seconds, and closed with a broken pipe on every attempt.

Keep the generation invalidation semantics, but monitor the enclosing
`connectTo` action instead of replacing the standard LSQ mini-protocol
callback. A timeout then cancels the whole mux connection, which is the unit
that the reconnect supervisor already owns, while the live LSQ peer continues
to use `mkMiniProtocolCbFromPeer`.

## Slice 2: live connection regression correction

One bisect-safe correction commit:

1. Use the existing devnet E2E suite as the live-boundary RED; bound the command
   externally so the regression fails instead of occupying a runner forever.
2. Restore the standard LSQ mini-protocol callback in both N2C applications.
3. Race each enclosing N2C connection against the channel generation monitor.
4. Preserve the node-free timeout, sibling wake-up, and connection termination
   assertions.
5. Run focused unit GREEN, live devnet GREEN, and the exact aggregate Nix build
   used by GitHub CI.

## Files

- `lib/Cardano/Node/Client/N2C/Types.hs`
- `lib/Cardano/Node/Client/N2C/LocalStateQuery.hs`
- `lib/Cardano/Node/Client/N2C/Connection.hs`
- `test/Cardano/Node/Client/N2C/LocalStateQuerySpec.hs`
- `test/unit-main.hs`
- `cardano-node-clients.cabal`

Slice 2 is expected to remain within the three N2C implementation/test modules;
the existing E2E harness supplies the live-node proof without fixture changes.

## Compatibility and risk

`newLSQChannel` and all query helpers keep their existing types. The new
constructor is additive. The principal risk is a false timeout for unusually
slow ledger evaluation; the 60-second default matches the downstream mitigation
that exposed the bug, while the additive constructor permits an explicit
application budget.
