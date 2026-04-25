# Ledger Functional Layer API

The browser and any downstream application own transaction workspace state.
The ledger layer receives explicit inputs and returns explicit results.

## Request

Ledger operation requests are JSON:

```json
{
  "tx_cbor": "<hex-encoded Conway transaction>",
  "op": "tx.inspect",
  "args": {}
}
```

- `tx_cbor` is required and is the canonical transaction document for the
  operation.
- `op` names the pure ledger operation.
- `args` contains operation-specific JSON control-plane arguments.
- Fidelity-sensitive ledger values remain CBOR hex inside JSON fields.

For browser navigation:

```json
{
  "tx_cbor": "<hex>",
  "op": "tx.browse",
  "args": {
    "path": ["outputs", "#4", "assets"]
  }
}
```

## Response

Successful ledger operations return JSON:

```json
{
  "ledger_functional_layer": "cardano-ledger-functional/v1",
  "op": "tx.inspect",
  "result": {}
}
```

- `ledger_functional_layer` identifies the envelope version.
- `op` echoes the operation that ran.
- `result` is operation-specific JSON.
- Mutating operations MUST include the resulting transaction CBOR in
  `result.tx_cbor`.

## Initial Operations

### `tx.inspect`

Decode the supplied transaction CBOR with the Haskell ledger and return:

```json
{
  "inspection": {},
  "browser": {}
}
```

`inspection` is the compact transaction summary. `browser` is the root browser
view used by the UI tree.

### `tx.browse`

Decode the supplied transaction CBOR with the Haskell ledger and return the
browser view at `args.path`:

```json
{
  "browser": {}
}
```

The browser MUST send the full current `tx_cbor` on every browse operation.
The ledger layer MAY cache decoded values, but cache state is not authoritative.

## Compatibility

During the transition from the earlier browser prototype, the WASM executable
MAY accept legacy requests containing `method` and top-level `path`. New callers
MUST use `op` and `args.path`.
