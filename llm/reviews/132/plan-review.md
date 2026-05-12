# Plan Review — PR #132

Verdict: approved for task review.

The plan connects back to the accepted spec and keeps the work split
into vertical, bisect-safe slices. The main semantic correction from
the Spec Kit analysis is now reflected: proposal redeemers represent
guardrail scripts, not proposer or deposit-return credentials. The
proof strategy covers property tests for body-field redeemer indices,
artifact CBOR golden tests for the `cardano-cli` compatibility surface,
and a devnet smoke behind `GATE_FULL=1`.

Conditions for implementation:

- Use final body-field order when computing cert/proposal indices.
- Keep `NoProposalScript` + `SNothing` as the first consumer path for
  treasury-withdrawal proposals.
- Run the slice gate before each code handoff and the full
  `nix develop --quiet -c just ci` gate before finalization.
