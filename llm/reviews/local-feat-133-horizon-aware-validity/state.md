state: ReadyForExternalReview
pr: 134
branch: feat/133-horizon-aware-validity
issue: 133
slices:
  - sha: 091a5ec
    title: "feat: Cardano.Node.Client.Validity — horizon-aware upper-bound math"
    gates: [unit:9/9, fmt, hlint]
  - sha: a2315a8
    title: "feat: Provider.queryUpperBoundSlot for horizon-aware validity"
    gates: [unit:231/231, e2e:3/3, fmt, hlint]
  - sha: 18315b7
    title: "docs: horizon-aware validity helper page"
    gates: [fmt, hlint]
gate: nix develop --quiet -c just ci  (last run: green)
notes: |
  Solo author/reviewer; not self-approving on GitHub.
  Follow-up: wire queryUpperBoundSlot into amaru-treasury-tx wizards
  (separate ticket; PR #88 there gated this work on the manual cap).
