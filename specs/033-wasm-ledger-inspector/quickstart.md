# Quickstart: Consuming the Cardano-Ledger WASM Nix Module

**Feature**: 033-wasm-ledger-inspector
**Audience**: Haskell project authors who want to cross-compile a `cardano-ledger-*` subset to `wasm32-wasi`.

This walks through the minimum work a downstream flake needs to add the module and produce a `.wasm` artifact.

---

## Prerequisites

- A Haskell project that already builds natively under `haskell.nix` via `pkgs.haskell-nix.cabalProject'`.
- Flakes enabled (`experimental-features = nix-command flakes` in `~/.config/nix/nix.conf`).
- A Linux host (macOS works for most of the pipeline but is not yet part of the feature's CI matrix).

## Step 1 — Add the flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    haskellNix.url = "github:input-output-hk/haskell.nix";
    cardano-node-clients = {
      url = "github:lambdasistemi/cardano-node-clients";
      # pin to a concrete rev after this feature's first release
    };
  };

  outputs = { self, nixpkgs, haskellNix, cardano-node-clients, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ haskellNix.overlay ];
      };
      wasm = cardano-node-clients.lib.wasm;
    in {
      # ... see step 2
    };
}
```

## Step 2 — Build a WASM artifact for your ledger subset

Simplest path — let the module do the work:

```nix
packages.${system}.my-wasm-decoder = wasm.mkCardanoLedgerWasm {
  inherit pkgs;
  packages = [ "cardano-ledger-binary" "cardano-ledger-conway" ];
  extraCabalProject = ''
    packages: ./my-decoder
  '';
};
```

Then:

```bash
nix build .#my-wasm-decoder
```

`$out` contains the `.wasm` file your downstream tooling can load with `wasmtime` or `@bjorn3/browser_wasi_shim`.

## Step 2 (alternative) — Apply the overlay to your own `cabalProject'`

If you prefer to keep your existing `cabalProject'` configuration and just add the WASM override set:

```nix
project = pkgs.haskell-nix.cabalProject' {
  name = "my-project";
  src  = ./.;
  compiler-nix-name = "ghc9122";
  modules = [ wasm.haskellWasmOverlay ];
  cabalProjectLocal = wasm.cabalWasmProjectFragment;
};
```

Then build your WASM target as you normally would under `haskell.nix`.

## Step 3 — Run it

Server-side with `wasmtime`:

```bash
echo -n "<conway-tx-hex>" | wasmtime result/bin/my-wasm-decoder.wasm
```

In the browser, see `docs/inspector/inspector.js` in this repository for a reference loader using `@bjorn3/browser_wasi_shim@0.4.2`.

## Step 4 — Pin for determinism

The module's own pins are internal, but your project still needs a stable input for reproducibility:

```nix
inputs.cardano-node-clients.url = "github:lambdasistemi/cardano-node-clients/<rev>";
```

and a matching `flake.lock` entry.

## Common first-time gotchas

- **Forgetting the `haskellNix.overlay`** — `wasm.mkCardanoLedgerWasm` expects `pkgs` to already carry `pkgs.haskell-nix`. If you pass vanilla nixpkgs you'll get evaluation errors about missing attributes.
- **Mixing index states** — the module pins its own `index-state`. If your downstream `cabal.project` pins a later state, you may see resolver conflicts. Either align to the module's state or pass `indexState = "<your-state>"` to `mkCardanoLedgerWasm` (this disables the module's determinism guarantee — use with care).
- **Adding extra ledger packages that aren't in the tested set** — the module is validated with `cardano-ledger-api`, `cardano-ledger-binary`, `cardano-ledger-conway`. Adding `ouroboros-consensus` or `cardano-api` may reintroduce WASM blockers the override set does not cover; expect to iterate.

## Verifying correctness

Build the sample inspector in this repo to confirm your toolchain setup:

```bash
git clone https://github.com/lambdasistemi/cardano-node-clients
cd cardano-node-clients
nix build .#wasm-tx-inspector
echo -n "$(cat test/fixtures/conway/boot.hex)" | wasmtime result/bin/wasm-tx-inspector.wasm
```

A successful decode emits JSON matching `test/fixtures/conway/boot.expected.json`. If the fixture diffs cleanly, the toolchain is green end-to-end.

## Where to file issues

- Toolchain / override-set breakage: open an issue on `lambdasistemi/cardano-node-clients`.
- Missing ledger packages in the tested set: open an issue with the target package list and the downstream use case.
- Questions about the inspector's JSON schema: see `specs/033-wasm-ledger-inspector/data-model.md`.
