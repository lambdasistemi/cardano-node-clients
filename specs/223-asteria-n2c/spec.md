# Restore the Asteria workload on HEAD

As an Asteria workload operator, I want the indexer, transaction builders and game binaries to use the dependency set resolved by cardano-node 11.2.0, so the workload follows the chain and submits real game transactions on HEAD and the released mixed-version network.

The 2026-11-05 HEAD run fbc8893a40ffc5b130f6b4f787448e52-64-11 reported zero successful Asteria heartbeats and 37,339 false observations. Image bf48615 pins clients 428313dec43ca213a383c092d5fe8dc1b0cb4ab4, offering N2C v20; HEAD image 2e76d83f requires v23. Current clients main already uses v23 for queries/submission, but standalone ChainSync still offers v20. The readiness probe discards a terminated connection and reports the failure as chain replay.

Operator ruling, 2026-11-05: perform the full node 11.2.0 dependency bump, following cardano-balance-transaction PR51, rather than the exploratory backport. All N2C paths offer v23 with the matching consensus codecs. Legacy v20-only sockets are outside this client target; the consumer moves to existing release relay2 (10.7.1), retaining older nodes in the network. No protocol fallback or assertion weakening.

Acceptance requires actual node integration, readiness plus strictly advancing processed slots, deployment, accepted game transactions and settled singleton/ship consistency observations. Connection errors retain their reason and must not be labelled chain replay. Source pins and snapshots agree across Cabal and Nix. Local checks, hosted CI and one-hour Antithesis findings comparisons are distinct evidence.
