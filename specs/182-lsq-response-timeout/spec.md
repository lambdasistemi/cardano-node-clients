# Specification: bounded LocalStateQuery responses

## Priority user story

As an operator of a long-lived process sharing one N2C connection, I need a
LocalStateQuery request whose response is silently lost to fail within a
bounded time and invalidate the LSQ peer, so later work does not remain queued
forever behind a live-but-wedged mini-protocol.

## Scope

This specification resolves #182 and its regression-test follow-up #183. It
covers one-shot LSQ calls, explicit acquired sessions, and the connection-level
liveness signal used by `runNodeClient` and `runNodeClientFull`.

LocalTxSubmission deadlines, retry policy changes, command-line timeout flags,
and changes to query result semantics are out of scope.

## Functional requirements

- FR-001: `newLSQChannel` keeps its existing signature and applies a documented
  60-second response timeout.
- FR-002: callers can construct an LSQ channel with a shorter or longer positive
  timeout for tests and application-specific latency budgets.
- FR-003: the response deadline covers acquire acknowledgements, one-shot query
  results, acquired-session query results, and normal session release waits.
- FR-004: the request that first expires raises a typed
  `LocalStateQueryTimeout` containing the configured timeout in microseconds.
- FR-005: other callers already waiting on the same LSQ liveness generation
  stop promptly with `ConnectionLost` instead of waiting for individual
  deadlines.
- FR-006: expiration invalidates the active LSQ peer action. The exception must
  escape the mini-protocol callback so the enclosing mux connection can unwind
  and an existing reconnect supervisor can retry it.
- FR-007: a newly started LSQ peer monitors the current liveness generation;
  an old timeout signal must not poison every future reconnect attempt.
- FR-008: successful responses retain their existing behavior and public query
  APIs remain source-compatible.
- FR-009: asynchronous cancellation is not caught or translated into a timeout.

## Acceptance criteria

- AC-001: a node-free typed-protocol server accepts `Acquire`, accepts a query,
  and deliberately never returns `SendMsgResult`.
- AC-002: before the fix, the regression reaches its short outer test timeout
  while the query remains blocked.
- AC-003: after the fix, the first query fails as `LocalStateQueryTimeout`
  within the outer bound and the monitored peer action terminates with the same
  typed failure.
- AC-004: a second query queued behind the stalled query fails promptly as
  `ConnectionLost` when the first deadline invalidates their shared generation.
- AC-005: the regression runs in the unit suite without a real node, socket, or
  wall-clock wait longer than two seconds.
- AC-006: the full repository CI gate passes.

## Root cause

`queryLSQ`, `withAcquiredLSQ`, and `queryAcquiredLSQ` currently wait on result
`TMVar`s without a deadline. After `SendMsgQuery`, the peer retains the result
slot inside its pending `recvMsgResult` continuation. If the remote peer never
sends a result but the bearer stays open, that retained writer is still
reachable, so GHC cannot report `BlockedIndefinitelyOnSTM`. The caller and the
single serialized LSQ loop therefore remain live and blocked indefinitely.
