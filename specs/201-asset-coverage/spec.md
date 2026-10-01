# Spec — #201 asset query discloses network, coverage and freshness

Parent: #199. Issue: #201 (acceptance frozen in the issue body).
Builds on #200 wire schema v1 (`specs/200-asset-query/spec.md`).

## User story

As an integrator, when `utxos_with_asset` returns few or no outputs, I
can tell from the same response whether that is the chain's answer or a
limit of this index: which network it follows, what it covers, how
fresh it is, and which limit, if any, applies.

## Requirements

- **R1 Network.** Every successful asset answer states the network
  magic the serving follower connects with.
- **R2 Coverage.** Every successful asset answer states the coverage of
  the serving follower: its start (`origin` or a concrete point) and
  whether it indexes all addresses or a filtered address set.
- **R3 Freshness.** Every successful asset answer states the upstream
  freshness: `synced`, `catching_up`, `disconnected` or `stale`, the
  last observed upstream tip slot, and how many slots the answer's own
  `point` is behind that tip.
- **R4 Limits.** Every successful asset answer carries `limits`: the
  list of reasons the answer may differ from the chain-wide answer at
  `point`. An empty list is the only form that claims the chain's
  answer. Any filtered, partial-history, catching-up, disconnected or
  stale index names its limit there, whether `utxos` is empty or not.
- **R5 Snapshot relation.** `point` and `utxos` stay one storage read
  (#200 R6). `network` and `coverage` are fixed for the life of the
  serving process. `freshness` is live follower state sampled after
  that storage read; its lag is computed against the answer's own
  `point`, never against a separately read processed slot.
- **R6 Additive (C1/C4).** v1 fields and both v1 error answers keep
  their bytes and meaning. `utxos_at`, `ready` and `await` request and
  response bytes are unchanged.
- **R7 Stale bound.** The daemon takes `--stale-after-seconds N`
  (default 600): a connected upstream with no follower progress for
  more than N seconds is `stale`.
- **R8 Docs.** `docs/usage/utxo-indexer.md` documents each new field,
  its meaning, and the coverage, freshness and rollback limits.

## Wire additions (C1, success answer only)

```json
{"point": ..., "utxos": [...],
 "network": {"magic": 42},
 "coverage": {"start": "origin" | {"slot": 100, "blockHash": "<hex>"},
              "addresses": "all" | "filtered"},
 "freshness": {"status": "synced" | "catching_up" | "disconnected" | "stale",
               "tipSlot": 1300 | null,
               "slotsBehind": 66 | null,
               "secondsSinceProgress": 3},
 "limits": ["address_filter", "partial_history",
            "catching_up", "disconnected", "stale"]}
```

`limits` order is the order above; each entry appears at most once.
`asset_index_unavailable` and `invalid_asset_query` answers carry no
list and are unchanged.

## Freshness rules

Precedence: `disconnected` > `stale` > `catching_up` > `synced`.

- `disconnected`: the reconnect supervisor reports the upstream down.
- `stale`: upstream connected and the time since the follower's last
  progress (roll-forward applied, or upstream status change) exceeds
  the stale bound.
- `catching_up`: upstream tip unknown, or `slotsBehind` above the
  daemon's ready threshold (`--ready-threshold-slots`, as `ready`).
- `synced`: otherwise.
- `slotsBehind` = tip slot − `point.slot`, clamped at 0; `null` when
  the tip is unknown.

## Invariants (stable IDs)

| ID | Holds when | Fails observably when |
|---|---|---|
| J1 | `network.magic` equals the magic of the follower serving the store | another value is reported |
| J2 | `coverage` derives from the same follower configuration the daemon runs: no start point → `origin`; start point → that point; all addresses → `all`; address set → `filtered` | coverage disagrees with the running configuration |
| J3 | `freshness.status` follows the rules above for every combination of upstream state, last-progress age, tip and point | any combination classified otherwise |
| J4 | `limits` = {`address_filter` iff filtered, `partial_history` iff start ≠ origin, the status iff status ≠ `synced`}; empty only for full coverage and `synced` | a limit applies and is not listed, or one is listed that does not apply |
| J5 | `slotsBehind` is computed from the answer's own `point.slot` | it is derived from any other slot |
| J6 | v1 success fields, both v1 error answers, and `utxos_at`/`ready`/`await` bytes are unchanged | any of those bytes differs |
| J7 | against a devnet node: a synced daemon answers `synced` with empty `limits`; with the node stopped, it answers `disconnected` with `limits` naming it, from its cached store | either case answers otherwise |
| J8 | `--stale-after-seconds` sets the stale bound, defaults to 600, and a non-integer value is a usage error | flag ignored, other default, or bad value accepted |

## Decisions

- **Coverage is the serving process's follower configuration.** The
  store's build configuration is not yet recorded; a store reopened
  with a different start point or filter is #207. The shipped daemon is
  unaffected: its configuration is fixed (origin start, `IndexAll`).
  Docs state this limit.
- **#198 is not absorbed.** Its changes (start-point Haddock, the
  intersect-not-found diagnostic) live in the follower, outside this
  ticket's fence. The coverage docs state the cold-boot-only start
  point as it bears on coverage.
- **Stale uses wall-clock since last progress**, not slot-versus-clock
  arithmetic: it needs no genesis or era-history parameters.

## Out of scope

Restart, upgrade and migration (#202); recording the store's build
configuration (#207); fault-injection checks (#203); fields on
`asset_index_unavailable`.
