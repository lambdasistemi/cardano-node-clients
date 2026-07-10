# Tasks: bounded LocalStateQuery responses

## Slice 1: regression and liveness fix

- [X] T183 Add the node-free typed-protocol regression and capture the expected
  pre-fix hang as RED.
- [X] T182 Add the configurable typed LSQ deadline, wake sibling callers, abort
  the active peer on invalidation, and wire both N2C connection variants.
- [X] T182 Verify focused GREEN, explicit revert/restore RED→GREEN, and the full
  repository gate; commit the accepted slice with both task references.

## Slice 2: live connection regression correction

- [X] T182 Capture the live-node failure where the readiness client reconnects
  every five seconds while a healthy node forges continuously.
- [X] T182 Monitor the enclosing N2C connection without moving it off its
  calling thread, preserving the original manual stateful LSQ callback.
- [X] T183 Enable threaded E2E deadlines, verify live RED→GREEN, and run the
  exact aggregate Nix build used by GitHub CI with a finite outer deadline.
