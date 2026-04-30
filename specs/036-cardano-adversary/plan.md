# Implementation Plan: Cardano Adversary (PR B scaffold)

**Spec**: [`spec.md`](spec.md)
**Status**: Draft
**Last updated**: 2026-04-30

## Architecture

```
                +-------------------------------------+
                |    cardano-adversary daemon         |
                |    Cardano.Node.Client.Adversary.*  |
                |                                     |
   composer -- NDJSON --> Server.hs --> Daemon.hs     |
   parallel_                                          |
   driver_x.sh                                        |
   over UNIX                                          |
   SOCK_STREAM                                        |
                +-------------------------------------+
```

PR B keeps the diagram trivial: only `Server.hs` (NDJSON listener)
and `Daemon.hs` (entry point + signal handling). Misbehaviour code
arrives in PR C and beyond and lives under
`Cardano.Node.Client.Adversary.Misbehaviour.*` so the namespace is
already partitioned.

## Module layout

```
app/cardano-adversary/Main.hs            CLI parsing only.
lib/Cardano/Node/Client/Adversary/
    Daemon.hs                            entry, signals, sockets.
    Server.hs                            NDJSON dispatcher.
    Types.hs                             request/response types.
    RandomSource.hs                      typeclass + Antithesis impl.
specs/036-cardano-adversary/
    spec.md
    plan.md
    tasks.md
    contracts/control-wire.md
```

`Cardano.Node.Client.Adversary.Misbehaviour.ChainSyncFlap` arrives
in PR C and registers itself with `Server.hs`.

## Public surface (PR B)

```haskell
-- Cardano.Node.Client.Adversary.Daemon
data DaemonConfig = DaemonConfig
    { daemonControlSocket :: FilePath
    , daemonProducerHosts :: [HostName]
    , daemonProducerPort  :: PortNumber
    , daemonNetworkMagic  :: NetworkMagic
    }

runDaemon :: DaemonConfig -> IO ()
```

```haskell
-- Cardano.Node.Client.Adversary.Server
data Request
    = ReqReady
    | ReqChainSyncFlap ChainSyncFlapArgs    -- reserved, returns NotImplemented
    deriving (Show, Eq)

data Response
    = RespReady ReadyDetails
    | RespError ErrorReason
    | RespNotImplemented
    deriving (Show, Eq)

handleConnection :: Handler -> Socket -> IO ()
```

```haskell
-- Cardano.Node.Client.Adversary.RandomSource
class Monad m => RandomSource m where
    randomU64 :: m Word64

newtype Antithesis a = Antithesis { runAntithesis :: IO a }
    deriving (Functor, Applicative, Monad)

instance RandomSource Antithesis where
    randomU64 = Antithesis $ do
        haveCli <- doesExecutableExist "antithesis_random"
        if haveCli
            then readU64 <$> readProcess "antithesis_random" [] ""
            else randomIO
```

The `Misbehaviour.ChainSyncFlap` shim in PR B simply returns
`RespNotImplemented`; PR C swaps that out for a real handler.

## Testing approach

PR B's test suite exercises only the wire surface. No N2N connection
attempts.

| Test | What it asserts | Where |
|---|---|---|
| `ready` round-trip | Daemon starts, accepts connection, responds to `{"ready": null}` with a parseable `ReadyDetails`. | unit-tests |
| reserved endpoint | `{"chain_sync_flap": {...}}` returns `{"ok": false, "reason": "not-implemented"}`. | unit-tests |
| malformed JSON | Garbage bytes followed by `\n` get `{"error": "malformed json"}`. | unit-tests |
| unknown key | `{"banana": null}` gets `{"error": "unknown request"}`. | unit-tests |
| SIGTERM | Send SIGTERM, daemon unlinks socket and exits 0 within 5 s. | unit-tests (via `withDaemonProcess`) |
| `--help` | CLI prints usage and exits 0. | unit-tests |

## Nix flake outputs

Adds:

- `packages.${system}.cardano-adversary` — the executable.
- `packages.${system}.cardano-adversary-docker-image` — a docker
  image built via `dockerTools.buildImage`, mirroring the
  tx-generator's image recipe in `nix/cardano-tx-generator.nix`.
- `apps.${system}.cardano-adversary` — `nix run .#cardano-adversary`.

## CI

Extend `.github/workflows/publish-images.yaml` to also build and
push `cardano-adversary` to GHCR. The workflow already loops over a
list of image names; adding `cardano-adversary` is a one-line
change.

## Out of scope (deferred)

- Any N2N connection setup. PR C lifts the `Adversary.ChainSync.*`
  modules from
  [`cardano-foundation/cardano-node-antithesis/components/adversary/src/`](https://github.com/cardano-foundation/cardano-node-antithesis/tree/main/components/adversary/src/Adversary/ChainSync)
  into this package as `Cardano.Node.Client.Adversary.ChainSync.*`.
- Antithesis SDK fallback emission. The daemon never writes to
  `sdk.jsonl`; that's the composer driver's job.
- Persisted state files. Misbehaviour archetypes that need them
  (e.g. equivocation history) introduce their own files in their
  own specs.

## Risks

- **Surge-style supply chain drift.** `nodePackages.surge` was
  removed from `nixpkgs-unstable` on 2026-03-03; lesson: pin every
  external nix dep explicitly. The flake's existing `nixpkgs` pin
  applies to this package by default; no action needed beyond
  reusing the project flake.
- **Wire-spec drift between repos.** PR D in
  [`cardano-foundation/cardano-node-antithesis`](https://github.com/cardano-foundation/cardano-node-antithesis/issues/90)
  consumes this wire spec. Mitigation: include the `control-wire.md`
  link in the published Docker image's `LABEL org.opencontainers.image.documentation`.
