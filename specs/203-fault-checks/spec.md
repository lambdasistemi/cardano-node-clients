# Spec — #203 fault checks for the asset query

Parent: #199. Assurance on a product that already runs; shipped behaviour does not change.

## User story

A maintainer relying on the asset-query checks wants proof that they fail for the
behaviour they guard, not only on setup failure. For each guarded behaviour, CI runs
one check that builds the asset query with a controlled fault and passes only if the
guarding test fails on that fault's assertion.

## Requirements

- R1 Asset matching fault. A controlled fault in deciding which asset-index rows match
  the queried (policy, asset name) makes the test guarding asset matching fail on its
  assertion.
- R2 Snapshot/provenance binding fault. A controlled fault that takes the matches, the
  creation points and the indexed point from different snapshots makes the test
  guarding snapshot binding fail on its assertion.
- R3 One CI check per fault. Each fault is its own job in `.github/workflows/ci.yml`,
  runnable locally with the same `nix run --quiet .#<name>`.
- R4 Distinguishable outcome. Each fault check reports exactly one named outcome:
  `KILLED` (the named guarding test failed on its assertion; check exits 0),
  `SURVIVED` (the named guarding test passed under the fault; non-zero), or
  `SETUP-FAILURE:<reason>` (fault did not apply, harness failed, the named test did
  not run, or it failed by exception rather than assertion; non-zero, distinct from
  SURVIVED). Exit codes: 0 `KILLED`, 2 `SETUP-FAILURE:<reason>`, 3 `SURVIVED`; 1 means
  the faulted build itself failed while nix realised the check's closure (no
  `FAULT-CHECK` line; nix names the failing derivation). The runner never exits 1.
- R5 Shipped code unchanged. No fault switch is reachable from the shipped daemon,
  executables or library API.

## Invariants

- INV-1 (R1) With the matching fault, the matching check's outcome is `KILLED`, naming
  the guarding example; without the fault the same example passes.
- INV-2 (R2) With the binding fault, the binding check's outcome is `KILLED`, naming
  the guarding example; without the fault the same example passes.
- INV-3 (R4) For each check, the three outcomes are each produced by a real run: the
  fault (`KILLED`), the fault removed (`SURVIVED`), an induced setup defect
  (`SETUP-FAILURE:<reason>`). Only `KILLED` exits 0.
- INV-3b (R4) A test or check run by an existing CI job drives the runner through each
  of its own outcomes and asserts the exit code and outcome line.
- INV-4 (R4) The outcome is deterministic: the fault check yields the same outcome on
  repeated runs; a guard that kills only some runs is not a kill.
- INV-5 (R5) `git diff origin/main -- lib lib-utxo-indexer lib-block-indexer
  lib-tx-history-indexer app` is empty, and the stanzas of every shipped cabal
  component (main library, public sublibraries, executables) are byte-identical.
- INV-6 (R3) The fault checks do not go through the socket wire path (bug #212); their
  outcome does not depend on a socket race.
- INV-7 Every existing CI job (build-gate, build, e2e, unit, lint) stays green.

## Rejection behaviour

A fault check that cannot apply its fault, cannot find or run its named example, or sees
it fail by exception exits 2 with `SETUP-FAILURE:<reason>`. A faulted tree that does not
compile fails the nix build of the check with exit 1 and no outcome line. Neither case
reports `KILLED` or `SURVIVED`.

## Success

CI on the PR head shows the two new fault jobs green with `outcome=KILLED` in their
logs, plus all existing jobs green.
