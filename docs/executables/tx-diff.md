# tx-diff

`tx-diff` compares two encoded Conway transactions and prints the actionable
structural differences. It is meant for reviewing how two transaction builders,
scripts, wallets, or command lines differ before submission.

The executable understands:

- CBOR hex transactions
- raw CBOR transactions
- cardano-cli JSON transaction envelopes

It compares the transaction structure, optionally decodes Plutus datum and
redeemer data with Plutus blueprints, and renders a human diff.

## Install

Use the release artifacts unless you are developing the repository.

### macOS

`tx-diff` is published to the `lambdasistemi/homebrew-tap` Homebrew tap:

```bash
brew tap lambdasistemi/tap
brew install tx-diff
```

The release workflow builds and smoke-tests an Apple Silicon tarball named:

```text
tx-diff-<version>-aarch64-darwin.tar.gz
```

The tarball is attached to the matching GitHub Release, and the Homebrew
formula points at that release asset.

### Linux

Linux releases are attached to the
[GitHub Releases](https://github.com/lambdasistemi/cardano-node-clients/releases)
page as AppImage, DEB, and RPM artifacts:

```text
tx-diff-<version>-x86_64-linux.AppImage
tx-diff-<version>-x86_64-linux.deb
tx-diff-<version>-x86_64-linux.rpm
SHA256SUMS
```

For an AppImage:

```bash
chmod +x tx-diff-<version>-x86_64-linux.AppImage
./tx-diff-<version>-x86_64-linux.AppImage tx-a.cbor tx-b.cbor
```

For Debian or Ubuntu:

```bash
sudo apt install ./tx-diff-<version>-x86_64-linux.deb
```

For Fedora, RHEL, or compatible distributions:

```bash
sudo dnf install ./tx-diff-<version>-x86_64-linux.rpm
```

Verify downloaded artifacts with:

```bash
sha256sum -c SHA256SUMS
```

### Development Channels

Unreleased Linux builds can be published to the `dev-linux` prerelease.
Unreleased macOS builds can be published through the `tx-diff-dev` Homebrew
formula:

```bash
brew tap lambdasistemi/tap
brew install tx-diff-dev
```

Use these only when testing a branch before a normal release.

## Build From Source

```bash
nix develop -c just build
nix develop -c cabal run cardano-node-clients:exe:tx-diff -- tx-a.cbor tx-b.cbor
```

For a local development binary path:

```bash
nix develop -c cabal list-bin cardano-node-clients:exe:tx-diff -O0
```

## Quick Start

Compare two transactions:

```bash
tx-diff tx-a.cbor tx-b.cbor
```

Use a Plutus blueprint to decode application-level datum and redeemer fields:

```bash
tx-diff --blueprint plutus.json tx-a.cbor tx-b.cbor
```

Use a collapse-rules file to group repeated list-item diffs into semantic
views:

```bash
tx-diff --collapse-rules collapse.yaml --blueprint plutus.json tx-a.cbor tx-b.cbor
```

## CLI Reference

```text
tx-diff [--render tree|paths] [--tree-art ascii|unicode] \
  [--collapse-rules FILE] [--blueprint FILE ...] \
  [--resolve-n2c SOCKET --network-magic N] \
  [--resolve-web2 URL [--web2-api-key-file PATH]] \
  TX_A TX_B
```

Arguments:

- `TX_A`: first transaction input.
- `TX_B`: second transaction input.

Options:

- `--render tree`: render a grouped tree. This is the default.
- `--render paths`: render one changed path per line.
- `--tree-art ascii`: use ASCII connectors. This is the default.
- `--tree-art unicode`: use Unicode tree connectors.
- `--blueprint FILE`: load a Plutus blueprint. The option can be repeated.
- `--collapse-rules FILE`: load YAML rules for named list-diff views.
- `--resolve-n2c SOCKET`: resolve inputs against a local cardano-node Unix
  socket. Requires `--network-magic`.
- `--network-magic N`: network magic (e.g. `764824073` for mainnet,
  `2` for preview, `1` for preprod). Required alongside `--resolve-n2c`.
- `--resolve-web2 URL`: resolve inputs against a Blockfrost-compatible web2
  endpoint that exposes `GET <URL>/txs/<txid>/cbor`.
- `--web2-api-key-file PATH`: file containing the API key sent as the
  `project_id` header. Surrounding whitespace is stripped. Only valid with
  `--resolve-web2`. Falls back to the `TX_DIFF_WEB2_API_KEY` environment
  variable when this flag is absent; if neither is set, the request goes
  out without a key, which suits self-hosted Blockfrost-compatible
  endpoints.

Exit status:

- `0`: the decoded transactions are equal.
- `1`: the decoded transactions differ.
- `1`: input, blueprint, collapse-rule, or CLI parsing failed.

## Render Modes

Tree mode groups changed leaves by path:

```text
body
`- fee
   +- A: 1.038522 ADA (1038522 lovelace)
   `- B: 1.042614 ADA (1042614 lovelace)
```

Path mode is useful for scripts that want stable text lines:

```bash
tx-diff --render paths tx-a.cbor tx-b.cbor
```

Use Unicode tree art only when the output target preserves it:

```bash
tx-diff --tree-art unicode tx-a.cbor tx-b.cbor
```

## Blueprint Decoding

Without a blueprint, Plutus datum and redeemer data are rendered as raw Plutus
data. With `--blueprint`, `tx-diff` tries to decode that data into the open
application structure described by the blueprint.

```bash
tx-diff --blueprint plutus.json tx-a.cbor tx-b.cbor
```

Multiple blueprints are accepted:

```bash
tx-diff --blueprint order.plutus.json --blueprint pool.plutus.json tx-a.cbor tx-b.cbor
```

The decoder uses only unambiguous matches. If no blueprint argument matches, or
if multiple matches are ambiguous, that datum or redeemer remains rendered as
raw Plutus data. This keeps the diff honest: the tool does not invent
application semantics.

## Collapse Rules

Collapse rules are a YAML rendering layer for repeated list differences. They
do not change the transaction comparison. They only define named views over
changed list items so a user can read repeated application-level differences
without scanning every raw index.

Create `collapse.yaml`:

```yaml
version: 1

views:
  raw: hide

collapse:
  - name: swapOrders
    at: body.outputs
    match:
      required:
        - coin
        - datum.fields.4.fields.0.2
        - datum.fields.4.fields.1.2
```

Run:

```bash
tx-diff --collapse-rules collapse.yaml --blueprint plutus.json tx-a.cbor tx-b.cbor
```

### YAML Fields

- `version`: required schema version. Version `1` is the only supported value.
- `views.raw`: optional raw-list policy. `show` is the default; `hide`
  suppresses the raw branch only where named views exist.
- `collapse`: optional list of named overlay rules.
- `collapse[*].name`: required rendered view name, for example `swapOrders`.
- `collapse[*].at`: required absolute path to an array/list node, for example
  `body.outputs`.
- `collapse[*].match.required`: non-empty list of relative paths inside each
  changed list item.

### Path Syntax

Paths are dot-separated object keys and numeric list indexes. They are written
against the open transaction diff tree after blueprint decoding.

- `at` is absolute from the diff root, for example `body.outputs`.
- `match.required` is relative to one item under that list, for example `coin`
  or `datum.fields.4.fields.0.2`.
- The rule file has no wildcards, predicates, formulas, sums, deltas, or
  semigroup aggregation.

### Matching Semantics

A rule applies at its `at` path when that path is a changed list. For each
changed list item, the item is selected when all `match.required` paths exist
as changed leaves inside that item.

Selected leaves are transposed so the list index moves down to the changed
leaf. Exact equal A/B leaf pairs are grouped and rendered as index ranges.

Rules are overlays, not partitions. If two rules match the same list item, both
named views render their own projection.

### Raw View Policy

With `views.raw: show`, the original list diff remains available under a `raw`
branch when named views exist at that list path.

With `views.raw: hide`, the raw branch is omitted, but unrepresented diffs are
not dropped. Changed leaves, insertions, and deletions not represented by a
named view render directly under their original numeric indexes.

## Input Resolution

By default, `tx-diff` is offline: each input of either transaction renders as
an atomic `txId#ix` leaf. Two opt-in resolvers can attach the referenced
`TxOut` (address, coin, datum, reference script) to every input the resolver
can find. Both spending, reference, and collateral inputs are covered.

### N2C: local cardano-node

```bash
tx-diff \
  --resolve-n2c /run/cardano-node/node.socket \
  --network-magic 764824073 \
  tx-a.cbor tx-b.cbor
```

`--resolve-n2c` opens an N2C `LocalStateQuery` session against a running
node. It returns only *currently unspent* UTxOs: inputs whose referenced
output has already been consumed will not be resolved by this path.

The user owns the socket, so this path has no third-party exposure. The
resolver name reported in diagnostics is `n2c`.

### Web2: Blockfrost-compatible CBOR endpoint

```bash
# canonical: secret on disk, no exposure via `ps` or shell history
tx-diff \
  --resolve-web2 https://cardano-mainnet.blockfrost.io/api/v0 \
  --web2-api-key-file /run/secrets/blockfrost-mainnet \
  tx-a.cbor tx-b.cbor

# alternative: env var fallback when --web2-api-key-file is absent
TX_DIFF_WEB2_API_KEY=mainnetXXXX tx-diff \
  --resolve-web2 https://cardano-mainnet.blockfrost.io/api/v0 \
  tx-a.cbor tx-b.cbor
```

`--resolve-web2` issues one HTTPS GET per *distinct* referenced transaction
id (`GET <URL>/txs/<txId>/cbor`) and indexes into the decoded transaction's
outputs to recover the referenced `TxOut`. Spent inputs resolve through this
path because the provider returns the historical transaction.

**Privacy and trust.** Web2 resolution sends transaction identifiers to a
third party. The provider learns which transactions you are inspecting. Use
the N2C path or a self-hosted Blockfrost-compatible service when this is a
concern.

The resolver name reported in diagnostics is `web2`.

### Combining N2C and web2

When both flags are present, the N2C resolver is asked first: it is cheap,
local, and leaks nothing. The web2 resolver only sees the inputs N2C could
not resolve — typically inputs that are already spent.

```bash
tx-diff \
  --resolve-n2c /run/cardano-node/node.socket \
  --network-magic 764824073 \
  --resolve-web2 https://cardano-mainnet.blockfrost.io/api/v0 \
  --web2-api-key-file /run/secrets/blockfrost-mainnet \
  tx-a.cbor tx-b.cbor
```

### Unresolved inputs

If no configured resolver returns an entry for some input, `tx-diff` does not
fail: the input renders without the resolved subtree, the rest of the diff
continues, and one stderr line per unresolved input names the input and the
resolvers that were asked:

```text
tx-diff: input 8b3a…#0 not resolved by [n2c]
tx-diff: input 12ef…#1 not resolved by [n2c, web2]
```

The order in the bracket matches the order resolvers were tried.

## Tutorial: Swap Order Review

This example groups repeated output differences under a semantic `swapOrders`
view while keeping unmatched outputs visible by their numeric index.

`collapse.yaml`:

```yaml
version: 1
views:
  raw: hide
collapse:
  - name: swapOrders
    at: body.outputs
    match:
      required:
        - coin
        - datum.fields.4.fields.0.2
        - datum.fields.4.fields.1.2
```

Command:

```bash
tx-diff --collapse-rules collapse.yaml --blueprint plutus.json swap.cbor.hex bash.tx.json
```

Output shape:

```text
body
+- fee
|  +- A: 1.038522 ADA (1038522 lovelace)
|  `- B: 1.042614 ADA (1042614 lovelace)
+- outputs
|  +- swapOrders
|  |  +- coin
|  |  |  +- 0..4
|  |  |  |  +- A: 12371.863798 ADA (12371863798 lovelace)
|  |  |  |  `- B: 12503.280000 ADA (12503280000 lovelace)
|  |  |  `- 32
|  |  |     +- A: 12371.863797 ADA (12371863797 lovelace)
|  |  |     `- B:   8166.545306 ADA (8166545306 lovelace)
|  |  `- datum
|  |     `- fields
|  |        `- 4
|  |           `- fields
|  |              `- 0
|  |                 `- 2
|  |                    `- 0..4
|  |                       +- A: 12368583798
|  |                       `- B: 12500000000
|  +- 33
|  |  `- coin
|  |     +- A: 1041728.494694 ADA (1041728494694 lovelace)
|  |     `- B: 1041836.734694 ADA (1041836734694 lovelace)
|  `- 34
|     `- coin
|        +- A: 50006.200754 ADA (50006200754 lovelace)
|        `- B: 49897.956662 ADA (49897956662 lovelace)
`- totalCollateral
   +- A: 1.557783 ADA (1557783 lovelace)
   `- B: 1.563921 ADA (1563921 lovelace)
```

How to read it:

- `swapOrders` is the named rule result.
- `0..4` and `32` are original list indexes grouped at the changed leaf.
- `33` and `34` are unmatched output diffs that remain visible because the raw
  view is hidden but differences must not disappear.
- A and B are separate child rows, right-aligned per changed leaf.
- ADA amounts are shown in ADA and lovelace where the field is known to be a
  coin value.

The fixture output used while developing this feature is available in the
gist: <https://gist.github.com/paolino/0097174c0fd21c2c1e99c5c6b7e341b5>.

## Troubleshooting

`tx-diff: failed to decode input`
: Check that both transaction files are CBOR hex, raw CBOR, or cardano-cli JSON
  envelopes.

`tx-diff: failed to decode blueprint`
: The blueprint file is not valid JSON or is not in the supported Plutus
  blueprint shape.

`tx-diff: failed to decode collapse rules`
: The YAML is invalid, the version is unsupported, `views.raw` is not `show` or
  `hide`, or a rule is missing required fields.

The collapse view does not decode datum fields
: Pass the matching `--blueprint` file. Collapse paths are written against the
  decoded open tree when decoding succeeds, and against raw Plutus data when it
  does not.

The collapse view hides something I expected to see
: `views.raw: hide` only hides the raw branch where named views exist. Diffs
  not represented by a named view still render under numeric indexes. Use
  `views.raw: show` when you also want the full original per-index list view.

## Roadmap

The current release compares the two transaction bodies provided on disk and
optionally resolves their referenced UTxOs via N2C or a Blockfrost-compatible
endpoint (see *Input Resolution* above). The next planned capability is:

- **WASM support**: make the tx-diff engine available in browser and other
  WebAssembly environments.

## Specification Contract

The main user manual is this page. The lower-level Spec Kit contract for the
collapse-rule file lives in
[`specs/142-tx-diff-collapse-views/contracts/collapse-rules.yaml.md`](https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/142-tx-diff-collapse-views/contracts/collapse-rules.yaml.md).
