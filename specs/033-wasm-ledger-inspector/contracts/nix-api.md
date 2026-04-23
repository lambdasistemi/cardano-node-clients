# Contract: `cardano-node-clients.lib.wasm` Nix Module API

**Feature**: 033-wasm-ledger-inspector
**Audience**: downstream flake authors who want to cross-compile a `cardano-ledger-*` subset to `wasm32-wasi`.

This document pins the public Nix API this feature exposes. Anything not documented here is an implementation detail and may change without notice.

---

## Flake output surface

The feature adds a single new flake output tree:

```nix
outputs.lib.wasm = {
  cabalWasmProjectFragment = <string>;
  haskellWasmOverlay       = <haskell.nix overlay>;
  mkCardanoLedgerWasm      = { pkgs, packages, ... } -> <derivation>;
  forks                    = <attrset of vendored source-repository-package pins>;
};
```

Additionally, pre-materialized packages and checks for this feature's own inspector:

```nix
outputs.packages.<system>.wasm-tx-inspector   # .wasm + index.html bundle
outputs.packages.<system>.docs-site           # full MkDocs build embedding the inspector
outputs.apps.<system>.serve-docs              # local preview
outputs.apps.<system>.deploy-docs             # mkdocs gh-deploy wrapper
outputs.checks.<system>.wasm-smoke
outputs.checks.<system>.wasm-tx-inspector
outputs.checks.<system>.wasm-tx-inspector-tests
outputs.checks.<system>.docs-site
```

Existing flake outputs (the N2C client library, devnet helpers, chain-follower, existing e2e checks) are untouched.

---

## `cabalWasmProjectFragment`

- **Type**: a string containing cabal.project stanzas to be concatenated after the downstream consumer's own `cabal.project`.
- **Contents**: `if arch(wasm32)` block with per-package flags, `allow-newer`, `constraints: time installed`, and the `source-repository-package` entries listed in `forks`.
- **Intended use**: downstream flakes that use their own `cabal.project` can splice this fragment in at the right spot to inherit the override set without cut-and-paste.

## `haskellWasmOverlay`

- **Type**: a `haskell.nix` overlay, i.e. a function of the shape `final: prev: { ... }` applied to `pkgs.haskell-nix`.
- **Contents**: the same fork pins and flags as `cabalWasmProjectFragment`, but expressed as `haskell.nix` overrides so a caller using `cabalProject'` can apply them programmatically.
- **Intended use**: downstream flakes that build via `pkgs.haskell-nix.cabalProject'` and prefer to merge overlays rather than concatenate cabal.project fragments.

## `mkCardanoLedgerWasm`

- **Signature**:
  ```nix
  mkCardanoLedgerWasm :: {
    pkgs     : <nixpkgs with haskell-nix overlay>;
    packages : [ <string> ];             # ledger packages to include, e.g. [ "cardano-ledger-api" "cardano-ledger-conway" ]
    extraCabalProject ? ""   : <string>; # optional extra cabal.project text appended
    ghcVersion ? "9.12"      : <string>; # currently only "9.12" is supported
    indexState ? <default>   : <string>; # Hackage index-state; defaults to the feature's pinned value
  } -> <derivation>
  ```
- **Output**: a derivation whose `$out` contains a `.wasm` file (and, where relevant, an accompanying `index.html` and a `bin/` symlink). The exact output layout is considered stable within a feature version.
- **Intended use**: one-call turnkey WASM build for a chosen ledger subset. The caller does not need to know about fork pins, cabal flags, or the two-phase FOD mechanics; the builder wires them all.

## `forks`

- **Type**: an attrset of `{ name, owner, repo, rev, sha256, subdir ? null }` records, one per vendored `source-repository-package` pin.
- **Intended use**: lets downstream consumers introspect which pins are in use, and lets this repository's own CI compute a materialized `cabal.project` snippet without duplicating the list.
- **Not part of the contract**: the set of keys inside `forks` may grow or shrink between feature versions; only its shape (attrset of records with the fields above) is guaranteed.

---

## Versioning

- The contract described here is stable within the lifetime of feature `033-wasm-ledger-inspector`.
- Breaking changes to any of `cabalWasmProjectFragment`, `haskellWasmOverlay`, `mkCardanoLedgerWasm` require a new feature (new spec + plan + PR) and a migration note for downstream consumers.
- The vendored `forks` map MAY change between minor updates (pin bumps, added entries, removed entries made unnecessary by upstream fixes) without breaking the contract.

## Non-goals

- This contract does not expose `cardano-api`, `ouroboros-consensus`, or `cardano-node` builds. Callers needing those must file a new feature.
- This contract does not commit to a GHC-JS backend for the same closure. GHC-JS is a future possibility but not part of this feature.
- This contract does not expose native (non-WASM) builds of the ledger closure; those remain the domain of the downstream consumer's own `haskell.nix` configuration.
