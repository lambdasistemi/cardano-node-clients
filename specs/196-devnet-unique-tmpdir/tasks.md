# Tasks — 196

## S1 — unique per-run working directory

- [ ] T001 RED: e2e spec proving INV-1, INV-2, INV-3, INV-4, registered in `e2e-tests`, failing on the fixed-path base for the isolation reason
- [ ] T002 GREEN: unique allocation inside bracket acquire, release terminates node then removes only the allocated directory (INV-1..INV-3, INV-6, INV-7)
- [ ] T003 Docs: README devnet component and any user-facing devnet docs state FR-7 (INV-8)
- [ ] T004 Frozen gate green on the head (all CI jobs), INV-5 holds with no caller edits
