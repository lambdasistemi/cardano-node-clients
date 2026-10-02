# Gate map — #220 intake proposal

Read from `.github/workflows/ci.yml`, `nix/checks.nix` and `justfile` at
`1b3bf8b03d44de7db073b766c4a18b1065febfcf`. Keep every existing CI check.
This planning commit adds no executable gate. All #220 proof is PLANNED;
no feature RED, socket-fault KILLED or remote CI result is claimed here.

## Existing build-gate command (preserved in full)

```sh
nix build --quiet \
  .#checks.x86_64-linux.build \
  .#checks.x86_64-linux.unit \
  .#checks.x86_64-linux.e2e \
  .#checks.x86_64-linux.lint \
  .#checks.x86_64-linux.fault-check-runner \
  .#checks.x86_64-linux.fault-asset-matching \
  .#checks.x86_64-linux.fault-snapshot-binding \
  .#checks.x86_64-linux.fault-view-snapshot-binding
```

After intake acceptance append
`.#checks.x86_64-linux.fault-socket-view-snapshot-binding` to this same command
(CI change in this ticket). Preserve release-version and downstream jobs.

## Check membership and acceptance mapping

All commands assert exit 0; fault checks additionally require KILLED.
Packaged CI commands below own their Nix toolchain; local Cabal/just work is
inside `nix develop`, with `just` pinning `-O0`.

| Acceptance / failure class | CI job and exact command | Required evidence |
|---|---|---|
| All existing derivations and new fault | `build-gate`: full command above plus planned new attribute | Every required check builds; record store/cache realization separately from rerun. |
| Library and both executables | `build`: `nix run --quiet .#build` | Realized library, utxo-indexer-lib and both executables. |
| Dev-shell build/unit/format/lint | `dev-shell`: `nix develop --quiet -c bash -c 'cabal update && just ci'` | Build/unit execute; format and HLint clean. |
| Required local candidate CI | Local: `nix develop --quiet -c just ci` | Exact committed SHA/tree, full log read, exit/duration/hash. |
| Batch schema, contents, point, refusal and legacy bytes | `unit`: `nix run --quiet .#unit` | New socket specs registered/executed and every existing unit spec green. |
| Existing live devnet regression surface | `e2e`: `nix run --quiet .#e2e` | Full existing E2E suite executes on real devnet; separate from local socket proof. |
| Cabal formatting, fourmolu, HLint | `lint`: `nix run --quiet .#lint` | No formatting drift or hints; inherited tool semantics preserved. |
| Release version contract | `build-gate`: `scripts/release/check-version-consistency` | Version contract exits 0; no release is authorized. |
| Fault-runner classification | `build-gate`: `.#checks.x86_64-linux.fault-check-runner` in full build command | Existing runner cases execute; zero failures, missing/skipped examples rejected. |
| Inherited asset maintenance | `fault-asset-matching`: `nix run --quiet .#fault-asset-matching` | Existing production fault KILLED; unchanged guard. |
| Inherited asset snapshot binding | `fault-snapshot-binding`: `nix run --quiet .#fault-snapshot-binding` | Existing asset fault KILLED; unchanged guard. |
| Inherited library view binding | `fault-view-snapshot-binding`: `nix run --quiet .#fault-view-snapshot-binding` | Existing library fault KILLED; does not substitute for socket fault. |
| New socket atomicity / point contents | Planned `fault-socket-view-snapshot-binding`: `nix run --quiet .#fault-socket-view-snapshot-binding` | CI change in this ticket; separate singleton views rejected on model contents, outcome=KILLED. |
| Required user docs accuracy | `unit` wire cases plus independent source review of `docs/usage/utxo-indexer.md` | ADVISORY invariant; no existing PR docs-accuracy CI command. Required review, not inferred from green CI. |

The existing `docs` deployment job remains main-only, needs build/e2e/unit/lint,
and runs `nix develop --quiet -c mkdocs gh-deploy --force`. Preserve its wiring;
publishing it is outside this seat's authority and is not a PR acceptance proof.

## Planned socket fault wiring (CI change in this ticket)

- Add production-only `nix/faults/socket-view-snapshot-binding.patch`, changing
  only batch dispatch to ordered singleton `readView` calls. The library,
  normal tests and model assertions remain unchanged under this mutation.
- Add a `mkFaultSpec` entry in `nix/checks.nix` using the patch and exact path:
  `utxo-indexer socket read view/every answer equals independent state at the reported point across a controlled advance`.
- Register the new socket spec and its helpers in `fault-check-main.hs` and
  the Cabal fault component; also register it in `unit-main.hs`/unit component.
- Existing export machinery surfaces both
  `checks.x86_64-linux.fault-socket-view-snapshot-binding` (runCommand invokes
  the shared script) and `apps.x86_64-linux.fault-socket-view-snapshot-binding`.
- Add the build-gate attribute and a downstream job with `needs: build-gate`,
  using `nix run --quiet .#fault-socket-view-snapshot-binding` as its command.
  No gate authors, bespoke untracked scripts or removed inherited checks.

## Falsification and acceptance receipts

Before feature implementation, execute the new normal socket specs on the
pre-feature server: missing request behavior must produce assertion RED.
After implementation, run the same normal guard GREEN with the witnessed
advance and complete response/model comparison specified in `plan.md`.
Apply/compile the socket fault and execute exactly that guard: require content
mismatch RED, then outer runner KILLED exit 0. Handshake, socket setup, patch,
build and example-selection failures are setup failures, never behavioral RED.
Emit executed-example/pending counts, P/Q identities, writer acknowledgement,
query/holder counts and expected/actual mismatch detail; zero/skip is not GREEN.

Falsify legacy byte comparison with deliberate byte changes and validation
with invalid later elements. Confirm unavailability never becomes an empty
success, beside an available no-match control. Keep the inherited fault
receipts independent. Record one real RED per changed proof command/failure
class; do not manufacture compile/lint faults for this docs-only phase.
Do not call planned commands green, falsified or missing-feature-tested.

Bind each implementation receipt to candidate SHA/tree, exact command, exit,
duration, full-output hash/path, invocation count, setup failures and cache
state. Full CI on the pushed PR head and a fresh auditor verdict are separate
requirements owned by the parent. Local unit GREEN is not remote CI GREEN.

## Docs-only planning verification

Run `git diff --check`; confirm changes are only this directory's Markdown,
each file ≤160 lines/12 KiB, total ≤650 lines/45 KiB. Commit the planning
candidate, run `commit-gate HEAD` and required local
`nix develop --quiet -c just ci` through `run-receipt`; preserve/read complete
output and bind its receipt to SHA/tree. No implementation RED or model-signature
hash is applicable. A planning-CI pass establishes existing regression checks
only; intake acceptance and every new behavioral proof remain outstanding.
