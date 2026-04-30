# Tasks: Cardano Adversary (PR B scaffold)

**Spec**: [`spec.md`](spec.md)
**Plan**: [`plan.md`](plan.md)
**Tracking issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/102

Each task lands as one bisect-safe commit on the
`feat/cardano-adversary-scaffold` branch. Order matters: skipping
forward leaves an uncompilable tree.

## Tasks

- **T001 — cabal target.** Add `executable cardano-adversary` to
  `cardano-node-clients.cabal` with `hs-source-dirs:
  app/cardano-adversary`, `main-is: Main.hs`, and the same
  `build-depends` baseline as `cardano-tx-generator`. Add
  `lib/Cardano/Node/Client/Adversary/` modules to the existing
  `library`'s `exposed-modules` (initially empty stubs).
- **T002 — Types.** `Cardano.Node.Client.Adversary.Types`:
  `Request`, `Response`, `ChainSyncFlapArgs`, `ReadyDetails`,
  `ErrorReason`. ToJSON / FromJSON instances matching
  `contracts/control-wire.md` byte-for-byte.
- **T003 — RandomSource.** `Cardano.Node.Client.Adversary.RandomSource`:
  the typeclass and the `Antithesis` newtype with the
  `antithesis_random`-CLI / `System.Random` fallback. Pure
  function `splitFromSeed :: Word64 -> RandomGen` so the daemon
  can derive a per-request `RandomGen` from the request's `seed`
  field.
- **T004 — Server.** `Cardano.Node.Client.Adversary.Server`:
  `handleConnection` reading one NDJSON line, dispatching to the
  request handler, writing one response, and closing. Pure JSON
  parse / render is in `Types`; this module owns the I/O.
- **T005 — Daemon.** `Cardano.Node.Client.Adversary.Daemon`:
  `runDaemon`, signal handling, control-socket bind + `0600` mode,
  `accept` loop using `forkFinally`. SIGTERM unlinks the socket
  and exits 0 within 5 s.
- **T006 — Main / CLI.** `app/cardano-adversary/Main.hs`:
  `--help`, required `--control-socket`, optional
  `--producer-host` (repeatable), `--producer-port`,
  `--network-magic`. Calls `runDaemon`. Mirrors the tx-generator's
  CLI shape so operators don't have to learn a second one.
- **T007 — Unit tests.** `test/AdversaryServerSpec.hs`: ready
  round-trip, reserved endpoint, malformed JSON, unknown key.
  `test/AdversaryDaemonSpec.hs`: SIGTERM unlinks socket, `--help`
  exits 0.
- **T008 — Nix flake outputs.** `packages.${system}.cardano-adversary`,
  `packages.${system}.cardano-adversary-docker-image`,
  `apps.${system}.cardano-adversary`. Mirror
  `nix/cardano-tx-generator.nix` in a sibling
  `nix/cardano-adversary.nix`.
- **T009 — Dockerfile.** `app/cardano-adversary/Dockerfile`
  for the non-Nix build path. Add
  `LABEL org.opencontainers.image.documentation=
  https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/036-cardano-adversary/contracts/control-wire.md`.
- **T010 — CI.** Extend
  `.github/workflows/publish-images.yaml` so
  `ghcr.io/lambdasistemi/cardano-adversary` is built and pushed
  alongside `cardano-tx-generator`.
- **T011 — Quality gate.** `nix develop -c just ci` green.
  Fourmolu, hlint, cabal-check, build, and tests all pass.
- **T012 — PR.** Open PR; link to
  [issue #102](https://github.com/lambdasistemi/cardano-node-clients/issues/102)
  and to the antithesis-side roadmap epic
  [#89](https://github.com/cardano-foundation/cardano-node-antithesis/issues/89).
  PR description summarises the wire surface so reviewers don't
  need to dig into the spec.

## Definition of done

- [ ] All T001–T012 commits land in order; each compiles.
- [ ] `cardano-adversary --help` works locally.
- [ ] `nix run .#cardano-adversary -- --control-socket /tmp/adv.sock`
      starts and responds to `printf '{"ready": null}\n' | nc -U
      -q 1 /tmp/adv.sock` with a JSON line.
- [ ] CI publishes `ghcr.io/lambdasistemi/cardano-adversary:<sha>`
      after merge.
- [ ] PR D in `cardano-foundation/cardano-node-antithesis` can pin
      the published image and consume the wire surface end-to-end.
