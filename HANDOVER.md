# Handover — Conway tx inspector (Haskell → wasm32-wasi → PureScript/Halogen UI)

You're picking up work on `lambdasistemi/cardano-node-clients`. The project builds a browser-loadable tx inspector using the upstream Haskell ledger code, cross-compiled to `wasm32-wasi`, with a PureScript + Halogen UI.

## Repo and branches

- Main repo: `/code/cardano-node-clients`
- Worktrees:
  - `/code/cardano-node-clients-wasm-inspector` → branch `033-wasm-ledger-inspector` (PR [#69](https://github.com/lambdasistemi/cardano-node-clients/pull/69)) — feature umbrella.
  - `/code/cardano-node-clients-wasm-devx` → branch `fix/wasm-devx` (PR [#71](https://github.com/lambdasistemi/cardano-node-clients/pull/71)) — DevX fix + UI polish. This is where you should work unless the task is explicitly for #69.
- Base for #71 is `033-wasm-ledger-inspector`. Rebase onto `main` once #69 merges.
- Open tracker issue: [#70](https://github.com/lambdasistemi/cardano-node-clients/issues/70) — DevX deep-dive.

## What runs today

Live preview: <https://cardano-tx-inspector.surge.sh>

- Browser UI (Halogen) with two input modes: **by tx hash** (fetches CBOR via Blockfrost or Koios) and **by CBOR hex** (paste). Pico.css v2 theming; password-typed credential inputs; opt-in persistence switch (off by default → in-memory only; on → `localStorage` cleartext, warned explicitly).
- Decoder is pure Haskell (`cardano-ledger-conway` + `cardano-ledger-binary` + `cardano-ledger-mary`, unchanged), cross-compiled to `wasm32-wasi` via `ghc-wasm-meta` GHC 9.12. Loaded in the browser via `@bjorn3/browser_wasi_shim`.
- Current JSON schema: era, decoder, `fee_lovelace`, `validity_interval`, `input_count` / `reference_input_count` / `output_count` / `cert_count` / `withdrawal_count` / `required_signer_count`, `inputs[]`, `reference_inputs[]`, `outputs[{address_hex, coin_lovelace, assets, datum}]`, `mint{}`.
- Koios in-browser requires a free bearer token (koios.rest intentionally strips CORS on anonymous requests — see [koios-artifacts#397](https://github.com/cardano-community/koios-artifacts/issues/397)). Blockfrost works with the free-tier `project_id`.

## Nix flake outputs (what to build)

```bash
# from /code/cardano-node-clients-wasm-devx
nix build .#packages.x86_64-linux.wasm-smoke          # cborg-only smoke (proves toolchain)
nix build .#packages.x86_64-linux.wasm-ledger-smoke   # full ledger closure smoke
nix build .#packages.x86_64-linux.wasm-tx-inspector   # THE decoder; ./result/wasm-tx-inspector.wasm
nix build .#packages.x86_64-linux.tx-inspector-ui     # PS bundle; ./result/{index.html,index.js}
nix build .#packages.x86_64-linux.devnet-genesis      # untouched pre-existing output

nix develop .#wasm-dev                                # host-side iteration shell (not fully working; see #70 open item)
```

## Build-cycle facts you need

- **Haskell-only edits to `nix/wasm/tx-inspector/wasm-tx-inspector/src/Conway/Inspector.hs`**: ~11 s rebuild. This is the fast path. The split builder (`prebuiltDeps` + `wasm`) keeps the ledger closure cached; Inspector edits only re-link the exe.
- **Edits to `wasm-tx-inspector.cabal` (adding build-depends)**: ~24 min, because `prebuiltDeps`'s `srcMetadata` filter picks up the cabal file change → its hash changes → full `wasm32-wasi-cabal build --only-dependencies` from scratch in a fresh sandbox.
- **Edits to `docs/inspector/src/*.purs` (UI)**: ~30 s via `nix build .#tx-inspector-ui`. Or iterate locally faster: `nix shell 'github:paolino/purescript-overlay/fix/remove-nodePackages#{purs,spago-unstable}' -c 'spago build'`.
- **FOD deps hashes**: hard-coded in `nix/wasm-targets.nix`. If you change forks or bump cabal deps, set `dependenciesHash = pkgs.lib.fakeHash`, build once, replace with the hash Nix prints.
- Key gotcha: `srcMetadata` in `nix/wasm/mkCardanoLedgerWasm.nix` must set `name = builtins.baseNameOf (toString src)`. Default `"source"` kills the cache because the sandbox extraction path won't match between `prebuiltDeps` and `wasm`.

## File layout you care about

```
nix/
  wasm/
    default.nix                       # public lib.wasm surface
    forks.json                        # vendored source-repository-package pins + nix32 hashes
    cabal-project-fragment.nix        # renders the `if arch(wasm32)` stanza
    mkCardanoLedgerWasm.nix           # ★ the builder; split into prebuiltDeps + wasm
    c-libs/                           # libsodium, secp256k1, blst for wasm32
    tx-inspector/
      cabal-wasm.project              # project file with SRP stanzas (rewritten at build time)
      wasm-tx-inspector/
        wasm-tx-inspector.cabal
        src/Conway/Inspector.hs       # ★ decoder → JSON
        app/Main.hs                   # WASI entry (stdin hex → stdout JSON)
    ledger-smoke/, smoke/             # sibling smoke targets
  wasm-targets.nix                    # wasm-smoke / wasm-ledger-smoke / wasm-tx-inspector wiring
  wasm-ui.nix                         # mkSpagoDerivation wrapper for tx-inspector-ui
  project.nix, fix-libs.nix           # native (non-wasm) cardano-node-clients lib
  checks.nix, apps.nix                # existing

docs/
  inspector/
    spago.yaml, spago.lock, package.json, package-lock.json
    dist/index.html                   # Pico.css v2 shell
    src/
      bootstrap.js                    # loads inspector.wasm via @bjorn3/browser_wasi_shim, exposes globalThis.runInspector
      Main.purs                       # ★ Halogen root
      Provider.purs                   # Blockfrost / Koios unified fetch
      FFI/Blockfrost.{purs,js}
      FFI/Koios.{purs,js}
      FFI/Storage.{purs,js}           # localStorage wrappers
      FFI/Clipboard.{purs,js}
      FFI/Inspector.{purs,js}         # PS → WASM via globalThis
      FFI/Json.{purs,js}              # JSON.stringify(_, null, 2) for Copy button

scripts/fetch-tx-cbor.sh              # CLI helper: hash → CBOR hex via Blockfrost
```

## Open follow-ups to consider

1. **Richer schema** — datum AST rendering (inline Plutus `Data`), redeemers (tag/index/data/ex_units), cert/withdrawal detail, bech32 addresses instead of hex. All fast-path Haskell edits. Start with `renderTx` in `Conway/Inspector.hs`; consult the new API via `Cardano.Ledger.Api` lenses (`rdmrsTxWitsL`, etc).
2. **Koios proxy** (optional) — small Cloudflare Worker that echoes Koios responses with `Access-Control-Allow-Origin: *` added so anon browser use works. Would remove the "bearer token required for browser" friction. Don't do without asking.
3. **Cachix for prebuiltDeps** — one-time team-wide cache so the first build isn't 24 min per contributor/CI runner.
4. **Full-fat `wasm-dev` shell** — currently can't clone SRP forks at runtime inside the shell. Needs `pkgs.fetchgit` pre-materialization + a patched `cabal-wasm.project` in the shellHook. Partial work already in `flake.nix`'s `devShells.wasm-dev`.
5. **Spec artifacts still point at the minimal schema** — update `specs/033-wasm-ledger-inspector/data-model.md` if you add more fields.

## Commit / PR hygiene you must follow

Read `~/.claude/CLAUDE.md` and the `workflow` / `purescript` / `haskell-wasm` / `nix` skills before touching code. Key rules from memory:

- Never include AI attribution (no "Co-Authored-By: Claude" lines, no "Generated with…" footers).
- Every issue/PR/CI reference in a reply **must** include a clickable URL.
- Push feature branches for browser review; commit small focused changes; rebase-merge linear history.
- Before every push: lint (`fourmolu`, `cabal-fmt`, `hlint`) + full local CI; don't push to trigger CI for debugging.
- Skills live under `/code/llm-settings/shared/skills/` — commit there if you learn something generally useful.

## Verification recipe

```bash
# from /code/cardano-node-clients-wasm-devx, branch fix/wasm-devx
nix build .#packages.x86_64-linux.wasm-tx-inspector
curl -s -H 'project_id: mainnetRuiuoEo0lhw6tJA3CGaVAoGM3kxIP11O' \
  https://cardano-mainnet.blockfrost.io/api/v0/txs/62e842c2b864776b2aec846fed1c1ad5810fa4dc12e12d44e8a53b18fdc828f9/cbor \
  | jq -r .cbor \
  | nix shell 'gitlab:haskell-wasm/ghc-wasm-meta?host=gitlab.haskell.org' \
      --command wasmtime result/wasm-tx-inspector.wasm \
  | jq .
```

Expected: structural JSON with `"era":"Conway"`, 125 outputs, 3 mint policies, `"cert_count":0`.

## Deploy preview after changes

```bash
nix build .#packages.x86_64-linux.tx-inspector-ui
rm -rf /tmp/tx-inspector-surge && mkdir -p /tmp/tx-inspector-surge
cp -rL result/* /tmp/tx-inspector-surge/
nix shell 'nixpkgs#nodejs_20' -c npx --yes surge /tmp/tx-inspector-surge cardano-tx-inspector.surge.sh
```

## If you're unsure

Ask before:
- Adding cabal build-depends (it's the 24-min path; we should know why).
- Changing `nix/wasm/mkCardanoLedgerWasm.nix` structure (that file is load-bearing for the DevX story; rerun the 11 s edit-cycle measurement after any change).
- Adding a new flake input (we minimize them deliberately).
- Deleting anything under `nix/wasm/`.

Good luck.
