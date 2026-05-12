# Tasks Review — PR #132

Verdict: approved for Slice A implementation.

The task list maps every acceptance criterion to an implementation
slice and names the RED proof for each behavior change. Slices A-D keep
tests and implementation folded into the same reviewed commit. Slice E
adds a compile-only public API check before opening the export surface.
Slice F covers the live devnet boundary smoke.

The task set is acceptable with these standing requirements:

- Do not implement proposal redeemers as proposer/deposit-return
  witnesses; only `GuardrailProposal` with a guardrail script hash
  emits `ConwayProposing`.
- Golden tests for the new cert/proposal artifacts must decode artifact
  CBOR directly, not reuse full-transaction fixture comparison.
- Review fixes go back into the slice commit that introduced the issue.
