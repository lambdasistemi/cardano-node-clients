# Tasks: bounded LocalStateQuery responses

## Slice 1: regression and liveness fix

- [X] T183 Add the node-free typed-protocol regression and capture the expected
  pre-fix hang as RED.
- [X] T182 Add the configurable typed LSQ deadline, wake sibling callers, abort
  the active peer on invalidation, and wire both N2C connection variants.
- [X] T182 Verify focused GREEN, explicit revert/restore RED→GREEN, and the full
  repository gate; commit the accepted slice with both task references.

## Slice 2: live connection regression correction

- [ ] T182 Capture the live-node failure where the readiness client reconnects
  every five seconds while a healthy node forges continuously.
- [ ] T182 Move LSQ generation monitoring to the enclosing N2C connection so
  the standard mini-protocol callback remains able to drive the live peer.
- [ ] T183 Verify RED→GREEN against the real devnet E2E suite and run the exact
  aggregate Nix build used by GitHub CI with a finite outer deadline.
