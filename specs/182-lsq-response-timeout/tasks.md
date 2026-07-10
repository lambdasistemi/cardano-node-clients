# Tasks: bounded LocalStateQuery responses

## Slice 1: regression and liveness fix

- [ ] T183 Add the node-free typed-protocol regression and capture the expected
  pre-fix hang as RED.
- [ ] T182 Add the configurable typed LSQ deadline, wake sibling callers, abort
  the active peer on invalidation, and wire both N2C connection variants.
- [ ] T182 Verify focused GREEN, explicit revert/restore RED→GREEN, and the full
  repository gate; commit the accepted slice with both task references.
