# Quickstart: Tx Diff Named Collapse Views

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

Run tx-diff:

```sh
tx-diff --collapse-rules collapse.yaml --blueprint plutus.json tx-a.cbor tx-b.cbor
```

Expected shape:

```text
body
`- outputs
   +- swapOrders
   |  +- coin
   |  |  `- 0..4
   |  |     +- A: 12371.863798 ADA (12371863798 lovelace)
   |  |     `- B: 12503.280000 ADA (12503280000 lovelace)
   |  `- datum
   |     `- fields
   |        `- 4
   |           `- fields
   |              `- 0
   |                 `- 2
   |                    `- 0..4
   |                       +- A: 12368583798
   |                       `- B: 12500000000
   `- 33
      `- coin
         +- A: 1041728.494694 ADA (1041728494694 lovelace)
         `- B: 1041836.734694 ADA (1041836734694 lovelace)
```

Use `views.raw: show` to keep the original list under a `raw` branch as an
audit view. With `views.raw: hide`, unmatched list diffs still render directly
under their original numeric indexes.
