# Implementation Plan: Provider acquired query session

**Branch**: `feat/provider-single-acquire-multi-query-session-for-at`
**Spec**: [spec.md](./spec.md)
**Issue**: [#126](https://github.com/lambdasistemi/cardano-node-clients/issues/126)

## Technical Context

**Language/Version**: Haskell, GHC 9.12.2 through Nix
**Primary Dependencies**: `ouroboros-network`, `ouroboros-consensus`, `cardano-ledger-api`, `stm`
**Storage**: none
**Testing**: Hspec E2E devnet, unit tests, `just ci`
**Target**: Public library API in `Cardano.Node.Client.Provider`

## Constitution Check

- Channel-driven N2C clients: preserved; new session API is still channel-driven.
- Devnet E2E testing: add an E2E provider test that uses a real devnet.
- Minimal dependencies: no new package dependencies.
- Test utilities first-class: no changes.

## Design

1. Add `QueryHandle m` to `Cardano.Node.Client.Provider`, exporting the type and selector functions but not the data constructor.
2. Add `withAcquired` to `Provider m`.
3. Add lower-level acquired-session support in `Cardano.Node.Client.N2C.LocalStateQuery`:
   - `withAcquiredLSQ :: LSQChannel -> (AcquiredLSQ -> IO a) -> IO a`
   - `queryAcquiredLSQ :: AcquiredLSQ -> Query Block result -> IO result`
4. Extend `Cardano.Node.Client.N2C.Types` with queue request variants for one-shot queries and acquired sessions.
5. Refactor `mkN2CProvider` to build a `QueryHandle` from a polymorphic query runner.
6. Keep existing one-shot provider fields as wrappers around `withAcquired`.

## Algorithm Sketch

```text
withAcquiredLSQ ch callback:
  create an acquired-session command queue
  enqueue "acquire this session" on the LSQ channel
  wait until the protocol client confirms MsgAcquired
  run callback with the acquired session
  enqueue release on the acquired-session queue
  wait for release acknowledgement

protocol client:
  wait for an LSQ request
  SendMsgAcquire VolatileTip
  if request is one-shot:
    SendMsgQuery
    put result
    drain queued one-shot/session requests if present
    otherwise SendMsgRelease
  if request is acquired-session:
    signal acquired
    serve session query commands until release command
    drain queued requests if present
    otherwise SendMsgRelease
```

## Files

- `lib/Cardano/Node/Client/Provider.hs`
- `lib/Cardano/Node/Client/N2C/Types.hs`
- `lib/Cardano/Node/Client/N2C/LocalStateQuery.hs`
- `lib/Cardano/Node/Client/N2C/Provider.hs`
- `test/Cardano/Node/Client/E2E/ProviderSpec.hs`
- `docs/modules/provider.md`

## Verification

Run:

```bash
nix develop --quiet -c just ci
```
