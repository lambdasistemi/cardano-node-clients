# Verification and delivery limits

The missing-socket probe regression executed against production code before its repair: 413 examples, one failure, one existing pending example; the observed event was node-replaying. After repair, the same 413 examples passed, retaining the existing pending example. The probe now races the connection runner against the query, so connection termination reaches the retry handler with its reason.

Local node integration: the old bf48615 image against HEAD 2e76d83f reproduces VersionMismatch [NodeToClientV_23] and null processed/tip slots. An upgraded indexer follows that exact node image, becomes ready at zero lag and advances processedSlot. All 40 client E2E examples pass against node 11.2.0, including standalone ChainSync and restart/governance cases. The Dijkstra fixture is copied from the node 11.2.0 template; the old fixture failed at minPoolMargin before forging.

The full development-shell just ci passes: build, 413 unit examples (zero failures, one existing pending), Cabal formatting, Fourmolu and HLint. Nix build/unit/lint checks pass. The Nix E2E/fault-check aggregate passes: 40 E2E examples, zero failures, all four seeded faults KILLED, and the fault-check runner self-test passes.

Consumer exploration also built the full Asteria image: HEAD and mixed-release relay2 both become ready and advance; bootstrap succeeds; player submission is accepted; subsequent node reads report ship_counter=1, ship_token_count=1 and admin singleton=1. Those are local development image observations, not final published image or hosted Antithesis acceptance.

The clients require N2C v23. No v20-only socket support is claimed. The consumer keeps old nodes in its mixed network and uses relay2's compatible socket. Ledger-read is pinned to the public candidate for upstream PR30; its merge state is a delivery dependency. No hosted CI, independent audit, merge, release or hosted Antithesis result is inferred from these local checks. Raw local receipts are under /tmp/asteria-n2c-repair on the author host.
