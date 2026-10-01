# Modules model (#198)

- **M1** `Cardano.Node.Client.UTxOIndexer.Follower` — unchanged
  responsibility and dependencies. Owns the warm-boot no-intersection
  message; may expose it (additively) so a unit check can observe the
  text the error path raises. See F1.
- No new modules.
