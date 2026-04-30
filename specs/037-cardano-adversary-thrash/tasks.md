# Tasks: chain_sync_thrash endpoint

**Spec**: [`spec.md`](spec.md)
**Plan**: [`plan.md`](plan.md)
**Tracking issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/107

Each task lands as one bisect-safe commit on `feat/chain-sync-thrash-impl`.

## Tasks

- **T201 — Wire types.** Extend
  `Cardano.Node.Client.Adversary.Types` with
  `ChainSyncThrashArgs`, `ChainSyncThrashDetails`,
  `ChainSyncThrashFailure`, the new `Request` and `Response`
  constructors, and ToJSON / FromJSON instances byte-for-byte
  matching `contracts/control-wire.md`. **Daemon hook still
  unchanged — `Server` returns `RespNotImplemented` for the new
  request.**
- **T202 — Server hook slot.** Extend `ServerHooks` with
  `hooksChainSyncThrash :: ChainSyncThrashArgs -> IO Response`.
  Default implementation in the daemon's `mkHooks` returns
  `RespNotImplemented`. Bisect-safe: the wire decode works, the
  endpoint responds, but with `RespNotImplemented`.
- **T203 — Chain-sync state machine for thrash.** Add a small
  helper alongside the existing `Application.hs` (or in a new
  `Cardano.Node.Client.Adversary.ChainSyncThrash` module): a
  `ClientStIdle` whose `recvMsgIntersectFound` /
  `recvMsgIntersectNotFound` callbacks both schedule another
  `MsgFindIntersect` until the bounded counter is exhausted, then
  `SendMsgDone`. Pure unit test that the chain-sync state
  machine's response matches the bound under a stub responder.
- **T204 — Top-level runner.** New module
  `Cardano.Node.Client.Adversary.ChainSyncThrash` exporting
  `runThrash :: DaemonConfig -> ChainSyncThrashArgs -> IO Response`:
  - clamp inputs;
  - read chain-points file (mirror of the flap path);
  - draw `producerHost` and the intersect-point stream from the
    request's `seed`;
  - call into T203's state-machine helper;
  - map per-connection outcomes onto the documented `Response`.
- **T205 — Daemon wiring.** Replace `mkHooks`'s
  `hooksChainSyncThrash` stub with `runThrash cfg`.
  End-to-end: `printf '{"chain_sync_thrash":...}\n' | nc -U
  /state/adversary-control.sock` against a local devnet returns a
  documented body.
- **T206 — Unit tests.** Extend `Adversary.ServerSpec` for the new
  wire shapes; new `Adversary.ChainSyncThrashSpec` covering the
  clamp, the determinism property (same seed → same producer
  choice), and the chain-sync state machine helper from T203.
- **T207 — Quality gate.** `nix develop -c just ci` green.
- **T208 — PR.** Open the PR; link to
  [issue #107](https://github.com/lambdasistemi/cardano-node-clients/issues/107)
  and to the antithesis-side roadmap epic
  [#89](https://github.com/cardano-foundation/cardano-node-antithesis/issues/89).

## Definition of done

- [ ] All T201–T208 commits land in order.
- [ ] `cabal run cardano-adversary -- --help` still works (no CLI
      regression — endpoint is configured per-request, not at
      startup).
- [ ] `printf '{"chain_sync_thrash":{"seed":1,"intersect_count":5,"settle_ms":50}}\n' | nc -U /tmp/adv.sock`
      against a daemon connected to a devnet returns
      `{"ok":true,"details":{"peerName":"...","intersectsIssued":5,...}}`.
- [ ] Producer's tracer shows ~5 `FindIntersect` events from the
      adversary peer in the same connection.
- [ ] CI publishes a fresh `ghcr.io/lambdasistemi/cardano-node-clients/cardano-adversary:<sha>`
      image after merge.
- [ ] Follow-up one-line PR in `cardano-foundation/cardano-node-antithesis` bumps
      the wrapper image's `cardano-node-clients` flake input + compose tag.
