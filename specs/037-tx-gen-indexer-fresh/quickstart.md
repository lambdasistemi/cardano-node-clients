# Quickstart: verifying the freshness gate locally

**Spec**: [spec.md](spec.md)
**Plan**: [plan.md](plan.md)

## Run the new E2E spec

The freshness gate is exercised end-to-end by `test/Cardano/Node/Client/E2E/TxGeneratorIndexFreshSpec.hs` (added by this feature). It:

1. Spins up a devnet relay via `withCardanoNode`.
2. Boots `cardano-tx-generator` against the relay's socket.
3. Waits until `ready=true` (steady state).
4. Stops the relay container/process so the supervisor logs `UpstreamDisconnected`.
5. Restarts the relay; waits for `setUpstreamStatus UpstreamConnected` to fire.
6. Within the post-reconnect window (before any new block), pings the refill arm and the transact arm, asserting both return `{"ok": false, "reason": "index-not-ready"}`.
7. Lets the chain produce one new block; reasserts both arms now proceed normally.

Run only this spec:

```bash
nix develop -c just e2e -- --match "Cardano.Node.Client.E2E.TxGeneratorIndexFreshSpec"
```

(or, if you prefer a focused run:)

```bash
nix develop -c cabal test e2e-tests -O0 \
    --test-show-details=direct \
    --test-options='--match "TxGeneratorIndexFreshSpec"'
```

## Reproduce the original failure mode (without the fix)

To convince yourself the gate matters, comment out the new check in `doRefill` and `doTransact` and re-run the spec — both assertions in step 6 will flip from `index-not-ready` to either `submit-rejected` (for refill) or `no-pickable-source` (for transact), reproducing the Antithesis failures named in the issue body.

## Full local CI

Run the same gates the GitHub job runs:

```bash
nix develop -c just ci
```

(Builds, runs all E2E specs, fourmolu check, hlint, cabal-fmt check.)

## Field-level cross-check after a reconnect storm

While running the daemon manually, you can observe the freshness gate via the daemon's structured output (no new field — the existing `index-not-ready` reason on arm responses is the signal). To distinguish freshness-gated short-circuits from other `index-not-ready` causes, grep the daemon log around a known reconnect timestamp and look at `setUpstreamStatus`/`updateReady` traces in adjacent lines.

## Companion PR for assertion thresholds

The Antithesis composer's `tx_generator_*_landed` Sometimes-assertion thresholds will be bumped in a separate PR in `cardano-foundation/cardano-node-antithesis`. End-to-end acceptance (the 1h `cardano_node_master` run with 0 Always-failures) requires *both* the gate from this repo and the threshold tweak from the companion repo.
