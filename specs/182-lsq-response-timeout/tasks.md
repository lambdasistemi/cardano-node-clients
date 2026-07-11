# Tasks: bounded LocalStateQuery responses

## Reopened bootstrap

- [X] T000 Create the follow-up worktree, verification gate, and draft PR
  #185 from released main.

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

## Slice 3: reopened live connection-loss follow-up

- [X] T182-S3 Add and observe RED for a connection terminating while an LSQ
  result wait still has a live deadline.
- [X] T182-S3 Signal connection termination to pending callers while preserving
  the underlying connection exception.
- [X] T182-S3 Diagnose the exact acquired evaluation query that terminates on
  the current mainnet node and implement only the proven minimal recovery.
- [X] T182-S3 Verify focused GREEN, revert/restore RED→GREEN, and the full
  `./gate.sh`; commit with `Tasks: T182-S3`.
- [X] T182-LIVE Parent follow-up: pin an Amaru candidate and produce unsigned
  CBOR for the exact colleague request five out of five times, with no
  witness/sign/submit artifacts.
