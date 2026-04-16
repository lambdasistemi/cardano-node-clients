# Implementation Plan: Validate Preview node 10.7.0 compatibility

## Summary

Align the repo’s local node sources with the Preview-era `cardano-node` `10.7.0` release by updating the Nix input, refreshing the lockfile, and keeping the devnet Docker image on the same version, then verify the existing E2E suite still passes unchanged.

## Technical Approach

1. Add a spec set for issue `#63` so the change follows the repo’s spec workflow.
2. Update the `cardano-node` input in `flake.nix` from `10.5.4` to `10.7.0`.
3. Refresh `flake.lock` for the `cardano-node` input so the shell resolves the matching release and revision.
4. Update `devnet/Dockerfile` so the standalone devnet image defaults to `10.7.0`.
5. Run the existing `e2e-tests` suite through the Nix dev shell and confirm the harness still works with the new node version.

## Risks

- `cardano-node` `10.7.0` may tighten config or genesis validation, which could require follow-up changes in the local devnet harness.
- Updating only one pin source would split the Nix shell and Docker devnet onto different node releases, reducing reproducibility.

## Verification

- Run `nix flake lock --update-input cardano-node`.
- Run `nix develop -c just e2e`.
