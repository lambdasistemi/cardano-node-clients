# Plan — #203

## Strategy

Faults exist only in test or check builds. Admissible seams (brief, epic owner):
a test-only seam, a flag-gated build of the same modules, or a patched copy of the
production source built only by the fault check. The commit owner picks one and
records why; whichever it is, INV-5 holds and the patched/flagged build is never
referenced by a shipped flake package, executable or library.

Guarding tests are the in-process asset specs (`test/Cardano/Node/Client/UTxOIndexer/
AssetIndexSpec.hs` and peers, suite `unit-tests`), not `AssetWireSpec` (INV-6). The
commit owner names the example that guards each behaviour. Where the current guard
does not deterministically fail under the fault (e.g. a concurrency test that kills
only on some interleavings), strengthening that test is in scope; the strengthened
test must still pass on unmodified production code in the `unit` job.

Each check is a `gateSpecs` entry in `nix/checks.nix` (becomes
`checks.<sys>.<name>` and `apps.<sys>.<name>` through the existing `mkGate` /
`nix/apps.nix`) and a CI job running `nix run --quiet .#<name>`; `build-gate` builds
its check derivation.

## Live boundaries

None. The fault checks are hermetic builds plus in-process tests.

## Slices

- S1 (one bisect-safe commit): both fault checks, their CI jobs, any guard
  strengthening, docs note. T001–T005.
