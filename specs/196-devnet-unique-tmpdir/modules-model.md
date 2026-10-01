# Modules model — 196

| ID | Module | Change | Responsibility |
|---|---|---|---|
| M-1 | `Cardano.Node.Client.E2E.Devnet` (`devnet` sublibrary) | changed, internal only | owns working-directory allocation, node lifecycle and removal of exactly the directory it allocated |
| M-2 | new e2e spec module under `test/Cardano/Node/Client/E2E/` | new | proves INV-1..INV-4 against real nodes; registered in `e2e-tests` |
| M-3 | `Cardano.Node.Client.E2E.Setup` | unchanged | inherits the fix through `withCardanoNode` |

Dependency direction unchanged: `e2e-tests` → `devnet` → `cardano-node-clients`.
Directory lifetime rules are in `data-model.md`; signatures in
`functions-model.md`.
