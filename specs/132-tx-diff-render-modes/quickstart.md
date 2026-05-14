# Quickstart: tx-diff Render Modes

## Tree Mode Smoke

Use two transactions that differ under a shared output or datum path:

```bash
tx-diff tx-a.cbor tx-b.cbor
```

This is equivalent to:

```bash
tx-diff --render tree --tree-art ascii tx-a.cbor tx-b.cbor
```

Expected:

- Shared parent path appears once.
- Changed leaves appear underneath.
- Side values are still labelled `A` and `B`.

## Path Mode Smoke

```bash
tx-diff --render paths tx-a.cbor tx-b.cbor
```

Expected:

- Changed leaves include full paths.
- No hierarchy-only parent lines are required to understand a changed leaf.

## Blueprint Smoke

```bash
tx-diff --render tree --tree-art ascii --blueprint plutus.json tx-a.cbor tx-b.cbor
```

Expected:

- Matching datum/redeemer fields are grouped under the ledger path.
- Decoded field names remain visible.

## Invalid Flag Smoke

```bash
tx-diff --render nope tx-a.cbor tx-b.cbor
```

Expected:

- Usage error.
- Non-zero exit.
- No transaction decode attempt.
