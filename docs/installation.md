# Installation

## Release artifacts

Released `utxo-indexer` builds for **x86_64 Linux** are attached to
each [GitHub release](https://github.com/lambdasistemi/cardano-node-clients/releases):

- `utxo-indexer-<version>-x86_64-linux.AppImage`
- `utxo-indexer-<version>-x86_64-linux.deb`
- `utxo-indexer-<version>-x86_64-linux.rpm`
- `SHA256SUMS`

The AppImage is self-contained; the `.deb` / `.rpm` install through
the system package manager.

## Nix

The flake exposes both executables as packages and apps. Run them
directly:

```bash
nix run github:lambdasistemi/cardano-node-clients              # utxo-indexer (default)
nix run github:lambdasistemi/cardano-node-clients#utxo-indexer
nix run github:lambdasistemi/cardano-node-clients#cardano-adversary
```

Or build them into `./result`:

```bash
nix build github:lambdasistemi/cardano-node-clients#utxo-indexer
nix build github:lambdasistemi/cardano-node-clients#cardano-adversary
```

The flake targets `x86_64-linux` and `aarch64-darwin`. The Linux
release artifacts (AppImage/deb/rpm) are produced by the
`linux-release-artifacts` package on Linux only.

## From source

Enter the development shell and build with `just` (which pins `-O0`
for fast iteration):

```bash
nix develop
just build   # library + utxo-indexer + cardano-adversary
```

See [Development](architecture.md) and the project `justfile` for the
full recipe list (`unit`, `e2e`, `format`, `hlint`, `ci`,
`serve-docs`).
