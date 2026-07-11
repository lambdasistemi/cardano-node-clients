# Specification: bounded LocalStateQuery responses

## Priority user story

As an operator of a long-lived process sharing one N2C connection, I need a
LocalStateQuery request whose response is silently lost to fail within a
bounded time and invalidate the enclosing N2C connection, so later work does
not remain queued forever behind a live-but-wedged mini-protocol.

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
- FR-006: expiration invalidates the active N2C connection action. A generation
  watcher must interrupt the connection caller so the whole mux session can
  unwind and an existing reconnect supervisor can retry it.
- FR-007: a newly started N2C connection monitors the current LSQ liveness
  generation; an old timeout signal must not poison future reconnect attempts.
- FR-008: successful responses retain their existing behavior and public query
  APIs remain source-compatible.
- FR-009: asynchronous cancellation is not caught or translated into a timeout.

## Acceptance criteria

- AC-001: a node-free typed-protocol server accepts `Acquire`, accepts a query,
  and deliberately never returns `SendMsgResult`.
- AC-002: before the fix, the regression reaches its short outer test timeout
  while the query remains blocked.
- AC-003: after the fix, the first query fails as `LocalStateQueryTimeout`
  within the outer bound and the monitored connection action terminates with
  the same typed failure without moving off its calling thread.
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

## Reopened follow-up: connection loss masked as timeout

Live verification on 2026-07-11 found that the released timeout bounds the
wait but does not preserve the existing fast connection-loss behavior. Five
fresh mainnet builds reached `evaluateTxH` and failed at the 60-second LSQ
deadline; the same control through v0.1.3.0 raised `ConnectionLost` in about
two seconds.

The deadline wait introduced a second liveness source: its `registerDelay`
`TVar` remains reachable and has a future writer. Consequently, a result
`TMVar` whose protocol peer has died is no longer eligible for GHC's
`BlockedIndefinitelyOnSTM` signal before the deadline. The explicit liveness
generation is advanced when a request expires, but not when the enclosing
connection action terminates independently.

### Follow-up functional requirements

- FR-010: termination of an N2C connection action advances that connection's
  LSQ liveness generation exactly once when it is still current.
- FR-011: a caller waiting for a response from the terminated generation
  raises typed `ConnectionLost` promptly, before its configured response
  deadline.
- FR-012: timeout-driven invalidation retains its existing distinction: the
  expiring request raises `LocalStateQueryTimeout`, while sibling waiters raise
  `ConnectionLost`.
- FR-013: the connection action's underlying exception remains observable to
  its supervisor and is not replaced by the caller-side deadline.
- FR-014: diagnosis must identify why the acquired `evaluateTx` query sequence
  terminates on the current mainnet boundary. Do not add an unbounded or blind
  retry that merely repeats an unknown protocol failure.
- FR-015: any retry introduced for an interrupted LSQ read is finite, begins
  from a fresh acquired state, and cannot apply to transaction submission.

### Follow-up acceptance criteria

- AC-007: a node-free peer/connection terminates while a query result is
  pending; the caller receives `ConnectionLost` within a short outer bound and
  not `LocalStateQueryTimeout`.
- AC-008: the regression is observed RED on v0.1.4.0 and GREEN after the fix,
  including explicit revert/restore proof.
- AC-009: the full repository gate passes.
- AC-010: the released Amaru disburse request, with 4,891.45 USDM represented
  as `4891450000` micro-USDM, produces non-empty unsigned CBOR in five out of
  five fresh mainnet runs.
- AC-011: the live proof creates no witness, signed transaction, or submission
  artifact.
