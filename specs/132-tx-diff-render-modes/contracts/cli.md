# CLI Contract: tx-diff Render Modes

## Command Shape

```text
tx-diff [--render MODE] [--tree-art ART] [--blueprint FILE ...] TX_A TX_B
```

## Render Mode

Accepted values:

- `tree`: human hierarchy mode.
- `paths`: flat path-line mode compatible with the first release.

Default:

- `tree`.

Invalid value:

- Print usage to stderr.
- Exit non-zero.
- Do not read `TX_A`, `TX_B`, or blueprint files.

## Tree Art

Accepted values:

- `unicode`: Unicode connector art.
- `ascii`: ASCII connector art.

Optional value:

- `plain`: indentation-only tree if the implementation decides it is useful
  and tests it.

Default:

- `ascii`.

Invalid value:

- Print usage to stderr.
- Exit non-zero.
- Do not read transaction inputs.

## Compatibility

`--render paths` must preserve the semantic meaning of the first release's
human output: every changed leaf line carries enough path context to be read
alone.

## Examples

```bash
tx-diff tx-a.cbor tx-b.cbor
```

Equivalent to:

```bash
tx-diff --render tree --tree-art ascii tx-a.cbor tx-b.cbor
```

```bash
tx-diff --render tree --tree-art unicode tx-a.cbor tx-b.cbor
```

```bash
tx-diff --render tree --tree-art ascii tx-a.cbor tx-b.cbor
```

```bash
tx-diff --render paths --blueprint plutus.json tx-a.cbor tx-b.cbor
```
