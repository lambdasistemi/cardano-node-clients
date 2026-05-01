# Phase 1 — Data Model: Indexer-fresh gate

**Spec**: [spec.md](spec.md)
**Plan**: [plan.md](plan.md)
**Research**: [research.md](research.md)

## Modified entity: `ReadyState`

Defined at `lib/Cardano/Node/Client/TxGenerator/Daemon.hs:217-223`.

### Before

```haskell
data ReadyState = ReadyState
    { rsReady :: !Bool
    , rsTipSlot :: !(Maybe Word64)
    , rsProcessedSlot :: !(Maybe Word64)
    , rsUpstream :: !UpstreamStatus
    }
```

### After

```haskell
data ReadyState = ReadyState
    { rsReady :: !Bool
    , rsTipSlot :: !(Maybe Word64)
    , rsProcessedSlot :: !(Maybe Word64)
    , rsUpstream :: !UpstreamStatus
    , rsIndexFresh :: !Bool
    }
```

Added field:

| Field          | Type   | Initial | Owners (writers)                                           |
|----------------|--------|---------|------------------------------------------------------------|
| `rsIndexFresh` | `Bool` | `False` | `setUpstreamStatus` (clears on Connected); `updateReady` (sets on `rollForward`) |

`initialReady` (Daemon.hs:225-232) gains `rsIndexFresh = False` to match cold-start semantics described in research.md Decision 6.

## State transitions

```
                       cold start / disconnect / reconnect
                                  │
                                  ▼
                         ┌─────────────────┐
                         │ rsIndexFresh =  │
                         │      False      │◄────────────────┐
                         └────────┬────────┘                 │
                                  │ first rollForward applied│
                                  ▼                          │
                         ┌─────────────────┐                 │
                         │ rsIndexFresh =  │                 │
                         │      True       │─────────────────┘
                         └─────────────────┘  setUpstreamStatus
                                              UpstreamConnected
                                              (next reconnect)
```

Edges:

- **Cold start** → `rsIndexFresh = False` (initial value).
- **`setUpstreamStatus UpstreamConnected`** → `rsIndexFresh = False` (unconditional, even if already false; safe).
- **`setUpstreamStatus (UpstreamDisconnected _)`** → `rsIndexFresh` unchanged in the model (it was already false, or we're about to reconnect and clear it again on the next Connected). The existing field in this branch sets `rsReady = False`; we do *not* need to mirror that for `rsIndexFresh` because the contract is "false until a fresh forward lands", and a disconnect cannot deliver one.
- **`updateReady` (called from `Follower.rollForward`)** → `rsIndexFresh = True` (alongside the existing `rsReady`/`rsTipSlot`/`rsProcessedSlot` updates).
- **`Follower.rollBackward`** → no direct effect on `rsIndexFresh`. Rollbacks happen *after* a forward has set freshness; they do not reset it. Rationale: a rollback inside the same connected episode means the chain-sync mini-protocol is alive and the indexer is consistent with the relay's view at the rollback point — staleness is not the issue.

## Invariant

Across all reachable states:

```
rsUpstream = UpstreamDisconnected _   ⇒   rsIndexFresh = False
```

Holds because `rsIndexFresh` can only flip to `True` via `updateReady`, which is only called from `rollForward`, which is only invoked while the chain-sync mini-protocol is live (which implies `rsUpstream = UpstreamConnected` at that moment, since the supervisor flips to `UpstreamDisconnected` on bearer failure).

The converse (`UpstreamConnected ⇒ rsIndexFresh = True`) is *not* an invariant — that is precisely the post-reconnect window the gate exists to handle.

## Read sites

Two new readers, both at the top of arm callbacks in `runDaemonWithTracer`:

- `doRefill` (Daemon.hs:399): reads `rsIndexFresh`; if `False`, returns `RefillFail IndexNotReady` and does not call `runRefillArm`.
- `doTransact` (Daemon.hs:419): reads `rsIndexFresh`; if `False`, returns `TransactFail IndexNotReady` and does not call `runTransactArm`.

Existing readers of `ReadyState` (`readyResponseFrom`, `snapshotResponseFrom`) remain unchanged; they observe `rsReady`/`rsTipSlot`/etc. as before. The freshness flag is purely an internal gate, not surfaced on the wire as a new field — the wire vocabulary stays at "ready=true/false + reason for not-applicable arm responses".

## Wire-protocol impact

**None.** `IndexNotReady` is already a `FailureReason` constructor (Types.hs:136), already serialised as `"index-not-ready"` (Types.hs:146), already retried by the composer. We are only adding a new code path that surfaces it in a new circumstance (post-reconnect, indexer not yet rolled forward).
