# Gate table v1 — #210 intake

S1 rows G01–G09; S2 retains them and adds G10–G12. Commands are CI
commands from `.github/workflows/ci.yml` at the base, or explicitly marked
CI changes in this ticket. Expected exit is 0 for each row. Existing rows
cannot be removed/reordered/weakened after slice dispatch.

| Row | Acceptance/failure class | Command | CI source |
|---|---|---|---|
| G01 | full required local dev-shell gate | `nix develop --quiet -c just ci` | required issue proof; add CI job in S1 |
| G02 | public API/build | `nix run --quiet .#build` | build |
| G03 | V1–V3, compatibility, model and provenance | `nix run --quiet .#unit` | unit; new specs registered by S1 |
| G04 | integration/regression | `nix run --quiet .#e2e` | e2e |
| G05 | format/lint | `nix run --quiet .#lint` | lint |
| G06 | existing asset guard | `nix run --quiet .#fault-asset-matching` | fault-asset-matching |
| G07 | existing point guard | `nix run --quiet .#fault-snapshot-binding` | fault-snapshot-binding |
| G08 | one-view atomicity behavioral RED control | `nix run --quiet .#fault-view-snapshot-binding` | new S1 app/check and CI job |
| G09 | release-version non-regression | `scripts/release/check-version-consistency` | build-gate |
| G10 | socket batch atomicity behavioral RED control | `nix run --quiet .#fault-point-read-snapshot-binding` | new S2 app/check and CI job |
| G11 | socket named-point refusal behavioral RED control | `nix run --quiet .#fault-point-read-point-check` | new S2 app/check and CI job |
| G12 | V4 and C4 normal socket behavior | `nix run --quiet .#unit` | unit; S2 socket specs registered |

The new fault checks return exit 0 only for KILLED: the intended single
example failed an expectation under the intended production fault. SURVIVED
and SETUP-FAILURE reject the gate; their diagnostic and original exit are
retained. Unfaulted examples must execute and pass in G03/G12.

Executables are ignored runtime artifacts (`gate.sh` and runtime backups),
bound by version/hash/base before each dispatch. This is the proposed command
table; executable hashes and falsification receipts do not exist at intake.
Missing new CI wiring blocks acceptance; a local-only fault run cannot close
G08/G10/G11. Existing CI's build-gate aggregation must retain all original
derivations and include the new fault derivations. Run commands inside the
repo's Nix shell where applicable; gate invocations retain their verbatim CI
spelling. Cheap/focused proof precedes expensive aggregate verification.

Evidence per row: head SHA, exact command, exit, duration, raw-output path and
sha256; faults also identify patched source and exact example/outcome. Record
normal GREEN and fault RED separately. No test is accepted by source grep.
No test, gate or baseline execution is claimed by this planning document.
