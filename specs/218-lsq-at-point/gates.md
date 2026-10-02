# Acceptance commands and evidence

All acceptance rows are **BLOCKING**. Run from the repository root. This intake
requires `git diff --check`, the four-file scope and combined 24 KiB / 450-line
ceiling, then one `nix develop --quiet -c just ci` invocation on the final docs
tree. Preserve its full log and command/head/tree/exit/duration/hash receipt.
No prose RED test, live e2e run or auditor build is allocated for intake.

## Implementation acceptance mapping

| Acceptance / invariants | Exact local command | Existing PR CI job and command | Required result |
| --- | --- | --- | --- |
| Additive API, peer target/refusal/lifecycle and compatibility: P1, P3-P5 | `nix develop --quiet -c just ci` | `dev-shell`: `nix develop --quiet -c bash -c 'cabal update && just ci'`; `unit`: `nix run --quiet .#unit`; `build`: `nix run --quiet .#build` | Exit 0, new peer cases executed and existing consumers compile. |
| Recent state at P after P < Q < R; real old and unknown refusals: P1-P3 | `nix develop --quiet -c just e2e` | `e2e`: `nix run --quiet .#e2e` | Exit 0; all three named live cases execute, no skips/pending. P/Q/R content/ordering and old anchor/refusal evidence retained. |
| Consumer docs and Haddock: P6 | `nix develop --quiet -c just ci` plus source review of examples against public API and snapshot types | `build`: `nix run --quiet .#build`; `lint`: `nix run --quiet .#lint` | Exit 0 and independent example review; these jobs alone do not prove prose semantics or live behavior. |

Future focused diagnostic command, **new-case coverage not available at intake**:
`nix develop --quiet -c cabal test e2e-tests -O0 --test-show-details=direct --test-options='--match "LocalStateQuery at point"'`.
This is the existing e2e recipe's Cabal invocation with a future case selector.
Confirm it executes all three intended live cases once implemented; a selector
matching zero tests is failure. Full `just e2e` remains required.

## All existing CI checks

Read from `.github/workflows/ci.yml` at the planning base. Each command must
succeed on the exact pushed implementation head; local `just ci` covers build,
unit, formatting and HLint, and does not execute live e2e or fault checks.

| Job / step | Verbatim command (multiline build step flattened) | Expected exit |
| --- | --- | --- |
| `build-gate` / Build all derivations | `nix build --quiet .#checks.x86_64-linux.build .#checks.x86_64-linux.unit .#checks.x86_64-linux.e2e .#checks.x86_64-linux.lint .#checks.x86_64-linux.fault-check-runner .#checks.x86_64-linux.fault-asset-matching .#checks.x86_64-linux.fault-snapshot-binding .#checks.x86_64-linux.fault-view-snapshot-binding .#checks.x86_64-linux.fault-socket-view-snapshot-binding` | 0 |
| `build-gate` / Release version contract | `scripts/release/check-version-consistency` | 0 |
| `build` | `nix run --quiet .#build` | 0 |
| `dev-shell` | `nix develop --quiet -c bash -c 'cabal update && just ci'` | 0 |
| `e2e` | `nix run --quiet .#e2e` | 0 |
| `unit` | `nix run --quiet .#unit` | 0 |
| `lint` | `nix run --quiet .#lint` | 0 |
| `fault-asset-matching` | `nix run --quiet .#fault-asset-matching` | 0 / KILLED |
| `fault-snapshot-binding` | `nix run --quiet .#fault-snapshot-binding` | 0 / KILLED |
| `fault-view-snapshot-binding` | `nix run --quiet .#fault-view-snapshot-binding` | 0 / KILLED |
| `fault-socket-view-snapshot-binding` | `nix run --quiet .#fault-socket-view-snapshot-binding` | 0 / KILLED |

The `docs` job deploys with `nix develop --quiet -c mkdocs gh-deploy --force`
only on main. It is not a PR acceptance check or authority to deploy locally.

## Behavioral controls and receipt limits

During implementation, compile and run the recent-point devnet test with the
specific-target production branch changed to VolatileTip; require a content
mismatch caused by querying Q-or-later state, then restore and require GREEN.
Likewise demonstrate the witness rejects per-query reacquisition. Node-free
controls swap the two refusal constructors and suppress/delay acknowledgement;
require the named refusal or bounded-liveness assertion to fail. Verify each
fault actually applies and executes; setup/compile failure is not behavioral
RED. Keep target traces, callback counts and post-refusal recovery results.
These planned controls add no intake tests or CI edits.

Cancellation controls are **PLANNED / outstanding** under the existing unit
command above: abandon an accepted request/late acknowledgement or suppress
cleanup at each applicable lifecycle barrier and require the caller-outcome
or subsequent-query assertion to fail. Verify the fault executes; restore and
require GREEN. A cancellation result alone cannot prove channel health. Keep
the plan's barrier/outcome/recovery records and bounds, including release races.
The full CI receipt for this docs tree proves none of these new behaviors.

Receipts bind base/candidate/tree, command, exit, duration, raw log hash and
paths, executed case counts and absence of skips. Distinguish owner-local CI,
real local devnet, node-free protocol tests, independent source audit and
remote CI. None stands in for another. Any inability to obtain P/Q/R contents,
observe the anchor, or produce either named live refusal remains blocking;
return it to the ticket owner without narrowing acceptance.
