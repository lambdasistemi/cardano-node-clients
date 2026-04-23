# Contract: Tx Inspector CLI

**Feature**: 033-wasm-ledger-inspector
**Audience**: consumers of `wasm-tx-inspector` (golden test harness, browser demo, downstream tooling)

The inspector is a WASI reactor whose only I/O is stdin, stdout, stderr, and exit status. It takes no arguments, reads no environment variables, makes no filesystem access beyond what WASI requires, and performs no network I/O.

---

## Invocation

```
wasmtime wasm-tx-inspector.wasm < <conway-tx-hex>
```

In the browser, the same contract holds via `@bjorn3/browser_wasi_shim`: stdin is seeded with the hex bytes; stdout is captured line-buffered.

## Input

- **Form**: a single line of lowercase or uppercase hex characters on stdin, terminated by EOF (trailing newline tolerated).
- **Content**: the CBOR-encoded body of a Conway-era `Tx`, exactly as it would appear on chain or in a `/tx/*` endpoint response.
- **Length**: bounded only by WASI memory limits; realistic mainnet-sized bodies must fit.

Invalid input (non-hex characters, odd-length hex, empty stdin, CBOR that does not parse as a Conway tx) triggers the error output described below.

## Output (success)

- **stdout**: a single JSON object matching `StructuralTxJSON` defined in `../data-model.md`, followed by a single newline. No trailing whitespace beyond that newline.
- **stderr**: empty.
- **exit status**: `0`.

Field ordering within the JSON is stable: top-level keys appear in the order `inputs`, `reference_inputs`, `mint`, `outputs`, `redeemers`. This lets fixtures be compared byte-for-byte with `diff`.

## Output (error)

- **stdout**: empty. No partial JSON may be written before an error is detected; the inspector buffers the full JSON internally before writing.
- **stderr**: a single line of the form `<category>: <detail>\n`, where `<category>` is one of `era_mismatch`, `malformed_cbor`, `structural_error`.
- **exit status**: non-zero. Specific exit codes are not part of this contract (any non-zero is acceptable).

## Guarantees

1. **No side effects** — no filesystem writes, no environment inspection, no network.
2. **No cryptography** — the decoder verifies no signatures, evaluates no scripts, and performs no fee calculations.
3. **Determinism** — for a given input, the output is a pure function of the input. Two invocations with identical stdin produce byte-identical stdout on success.
4. **Structural fidelity** — every field in `StructuralTxJSON` reflects the corresponding field of the decoded Conway tx body as the ledger itself interprets the bytes.
5. **Schema stability** — within a feature version, the output schema does not change. Schema evolution is a PR with a migration note in `data-model.md` and a fixture refresh.

## Non-guarantees

- The JSON is **not** a round-trippable serialization of the tx. Re-encoding it will not produce the original CBOR.
- The JSON does not include every field of the Conway tx body. Fields the feature does not need (certificates, withdrawals, network ID, validity interval, auxiliary data hash, collateral return, total collateral, etc.) are omitted by design and MAY be added in future features; their omission in this version MUST NOT be interpreted as their absence in the tx.
- The inspector is a decoder, not a validator. A tx that decodes cleanly may still fail ledger validation; that is outside scope.

## Error category reference

| Category | Meaning | Typical cause |
|---|---|---|
| `malformed_cbor` | Input did not parse as CBOR at all. | Truncated hex, invalid hex characters, non-CBOR payload. |
| `era_mismatch` | CBOR parsed, but the outer structure is a non-Conway tx. | Babbage or earlier era tx, or a non-tx CBOR document. |
| `structural_error` | CBOR parsed as a Conway-shaped document but a sub-field did not match the ledger's schema. | Corrupt output entry, unexpected redeemer tag, etc. |
