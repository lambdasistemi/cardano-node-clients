# Modules model — 197

| ID | Module | Change | Responsibility |
|---|---|---|---|
| M-1 | `Cardano.Node.Client.E2E.Devnet` (`devnet` sublibrary) | changed, additive exports | sole owner of the node lifecycle; runs the caller's hook between stop and spawn; exposes run/db paths |
| M-2 | new e2e spec module under `test/Cardano/Node/Client/E2E/` | new | proves INV-1..INV-3 against a real node; registered in `e2e-tests` and `test/main.hs` |
| M-3 | `Cardano.Node.Client.E2E.Setup`, existing specs | unchanged | INV-4 |

Dependency direction unchanged: `e2e-tests` → `devnet` → `cardano-node-clients`.
Lifecycle rules in `data-model.md`; signatures in `functions-model.md`.
