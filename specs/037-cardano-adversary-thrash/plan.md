# Implementation Plan: chain_sync_thrash endpoint

**Spec**: [`spec.md`](spec.md)
**Tracking issue**: https://github.com/lambdasistemi/cardano-node-clients/issues/107

## Architecture (delta against 036)

```
   composer ----> NDJSON ----> Server.hs (036)
                              dispatcher
                                  |
                                  +--> hooksReady           (existing)
                                  +--> hooksChainSyncFlap   (existing, 036)
                                  +--> hooksChainSyncThrash (new — this PR)
                                                |
                                                v
                  Cardano.Node.Client.Adversary.ChainSyncThrash
                                                |
                                                +--> ChainSync.Connection (existing, 036)
                                                +--> ChainSync.Codec      (existing, 036)
                                                +--> ChainPoints          (existing, 036)
                                                +--> RandomSource         (existing, 036)
```

Everything that existed in 036 stays exactly as it is. The new
endpoint adds one module and one hook.

## Module layout

```
lib/Cardano/Node/Client/Adversary/
    Application.hs            — existing; gains a small helper
                                'thrashApplication' that wraps the
                                ChainSync.Codec idiom for the new
                                ClientStIdle that only sends
                                MsgFindIntersect.
    ChainSyncThrash.hs        — NEW. Top-level driver, picks the
                                producer host via splitFromSeed,
                                reads chain points, runs the
                                bounded intersect loop, returns
                                Response.
specs/037-cardano-adversary-thrash/
    spec.md
    plan.md
    tasks.md
    contracts/control-wire.md
```

## Public surface (additions only)

```haskell
-- Cardano.Node.Client.Adversary.Types  (extend Request + Response)
data Request
    = ReqReady                                -- existing
    | ReqChainSyncFlap !ChainSyncFlapArgs     -- existing
    | ReqChainSyncThrash !ChainSyncThrashArgs -- new

data ChainSyncThrashArgs = ChainSyncThrashArgs
    { ctaSeed           :: !Word64
    , ctaIntersectCount :: !Word16   -- clamped [1, 1000]
    , ctaSettleMs       :: !Word16   -- clamped [0, 60000]
    }

data Response
    = RespReady !ReadyDetails                  -- existing
    | RespNotImplemented                       -- existing
    | RespChainSyncFlapOk !ChainSyncFlapDetails -- existing
    | RespChainSyncFlapFail !ChainSyncFlapFailure -- existing
    | RespChainSyncThrashOk !ChainSyncThrashDetails -- new
    | RespChainSyncThrashFail !ChainSyncThrashFailure -- new
    | RespError !ErrorReason                   -- existing

data ChainSyncThrashDetails = ChainSyncThrashDetails
    { cstdPeerName              :: !Text
    , cstdIntersectsIssued      :: !Word16
    , cstdIntersectCountClamped :: !Bool
    , cstdSettleMsClamped       :: !Bool
    }

data ChainSyncThrashFailure
    = CstfNoChainPointsFile          -- shared semantics with chain_sync_flap
    | CstfNoChainPointsYet
    | CstfNoProducers
    | CstfConnectionRefused          -- new for this endpoint
```

```haskell
-- Cardano.Node.Client.Adversary.Server  (extend ServerHooks)
data ServerHooks = ServerHooks
    { hooksReady           :: IO ReadyDetails                    -- existing
    , hooksChainSyncFlap   :: ChainSyncFlapArgs   -> IO Response -- existing
    , hooksChainSyncThrash :: ChainSyncThrashArgs -> IO Response -- new
    }
```

```haskell
-- Cardano.Node.Client.Adversary.ChainSyncThrash  (NEW)
runThrash :: DaemonConfig -> ChainSyncThrashArgs -> IO Response
```

## Reuse contract

| Concern | Source |
|---|---|
| N2N initiator handshake + chain-sync codec | `Cardano.Node.Client.Adversary.ChainSync.{Codec,Connection}` |
| Chain-points file parser + sampler | `Cardano.Node.Client.Adversary.ChainPoints` |
| Per-request determinism | `Cardano.Node.Client.Adversary.RandomSource.splitFromSeed` |
| Producer-host fan-out | none — this endpoint picks **one** producer, not all |
| Chain-sync state machine | New helper `thrashClient` in `Application.hs`, or a sibling module that owns the new ClientStIdle |

`runThrash` can be implemented in pure-IO without an STM TVar (no
chain accumulation needed — we never call `MsgRequestNext`). State
is just a counter for `intersectsIssued`.

## Testing approach

| Test | Where |
|---|---|
| `chain_sync_thrash` request decodes from documented JSON | `test/.../Adversary/ServerSpec.hs` (extend) |
| `RespChainSyncThrashOk` / each `Fail` variant encodes byte-for-byte | same |
| `intersect_count` clamping at the type/clamp helper | `test/.../Adversary/ChainSyncThrashSpec.hs` (new) |
| Same seed → same producer choice (determinism) | same |
| End-to-end: daemon answers thrash against an unreachable host with `connection-refused` | smoke step inside the existing devnet harness if cheap; otherwise leave for the antithesis-side compose smoke |

## Out of scope (deferred)

- Slow-loris (1.3) — same connection, slow `MsgRequestNext`. Lives
  in `038-cardano-adversary-slow-loris`.
- All Tier 2 / 3 / 4 endpoints.
- Antithesis-side compose tag bump — separate one-line PR after
  this merges (mirror of the PR D pattern).

## Risks

- **State-machine correctness in `ouroboros-network`.** The
  chain-sync client state machine permits sending another
  `MsgFindIntersect` after the previous one's
  `MsgIntersectFound` / `MsgIntersectNotFound` reply has been
  received. Verify against the spec; if intersect-after-intersect
  is *not* allowed in `StIdle`, the loop must instead disconnect
  and reconnect, which would defeat the point of the endpoint.
  Mitigation: prototype against a local devnet before claiming the
  request shape final.
- **Composer driver order with chain_sync_flap.** Both endpoints
  read the same chain-points file. If thrash holds a connection
  open while flap is firing, it shouldn't matter — they're
  separate connections — but worth a smoke run to confirm.
