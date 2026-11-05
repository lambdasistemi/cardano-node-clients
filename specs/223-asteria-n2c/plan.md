# Node 11.2.0 dependency alignment

Operator approved 2026-11-05: follow cardano-balance-transaction PR #51 (58a7df451be86fab4888d89aeeaf277198dc4345), solo. The full dependency bump replaces the exploratory backport.

Story: As a workload operator, I want Asteria to follow HEAD and released chains so gameplay runs rather than remaining permanently unready.

1. Freeze the node 11.2.0 tag in its own shell; bind Cardano ecosystem pins and index snapshots to that resolved set. Reuse ledger-read PR #30 where required.
2. Advance clients and adapt API changes. Use the protocol and codecs supported by consensus 5.2. Diagnose connection failures clearly.
3. Advance transaction tools and then Asteria; rebuild bootstrap, player, invariant checker and indexer consistently. Consumer uses the existing release relay2 (10.7.1), retaining the mixed-version node network.
4. Prove indexing readiness/progress and gameplay against actual HEAD and released nodes; run local gates and prepare exact candidate PRs. Publish/re-pin the image only after build validation; required hosted acceptance remains distinct from local evidence.

Evidence: /tmp/asteria-n2c-repair. Exact old Asteria image against exact HEAD already reproduces VersionMismatch [NodeToClientV_23], null processedSlot/tipSlot and unready indexer. No additional agents, unrelated checkout changes or weakened heartbeat checks.
