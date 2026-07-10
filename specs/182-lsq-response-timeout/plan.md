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

## Files

- `lib/Cardano/Node/Client/N2C/Types.hs`
- `lib/Cardano/Node/Client/N2C/LocalStateQuery.hs`
- `lib/Cardano/Node/Client/N2C/Connection.hs`
- `test/Cardano/Node/Client/N2C/LocalStateQuerySpec.hs`
- `test/unit-main.hs`
- `cardano-node-clients.cabal`

## Compatibility and risk

`newLSQChannel` and all query helpers keep their existing types. The new
constructor is additive. The principal risk is a false timeout for unusually
slow ledger evaluation; the 60-second default matches the downstream mitigation
that exposed the bug, while the additive constructor permits an explicit
application budget.
