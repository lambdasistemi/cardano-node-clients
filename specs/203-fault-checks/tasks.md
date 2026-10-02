# Tasks — #203

## S1 fault checks

- [ ] T001 F-MATCH fault and `fault-asset-matching` check, outcome KILLED on the matching guard (R1, INV-1, INV-4)
- [ ] T002 F-BIND fault and `fault-snapshot-binding` check, outcome KILLED on the binding guard (R2, INV-2, INV-4)
- [ ] T003 Outcome classifier: KILLED / SURVIVED / SETUP-FAILURE, each proven by a real run (R4, INV-3)
- [ ] T004 CI jobs + build-gate entries; shipped code unchanged (R3, R5, INV-5, INV-6, INV-7)
- [ ] T005 Docs: what each fault check proves and how to read its outcome line
