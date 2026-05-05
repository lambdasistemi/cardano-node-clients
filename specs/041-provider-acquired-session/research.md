# Research: Provider acquired query session

## Decision: Keep the public handle high-level

`QueryHandle m` exposes provider-shaped operations instead of raw consensus `Query Block result` values.

**Rationale**: `Cardano.Node.Client.Provider` is protocol-agnostic today. Exposing raw consensus queries there would leak N2C internals and force downstream registry-walk code to depend on lower-level consensus APIs.

**Alternatives considered**: Export a raw LSQ handle. Rejected because it would couple application code to the N2C implementation and bypass the existing provider abstraction.

## Decision: Model acquired sessions as a second queue

The main LSQ channel gets a new request variant that asks the protocol client to acquire and then serve commands from an acquired-session queue until a release command arrives.

**Rationale**: The protocol client must remain the only thread that sends `MsgQuery` and `MsgRelease`. A session queue lets user code run normally while the protocol thread preserves LocalStateQuery state.

**Alternatives considered**: Enqueue several ordinary `queryLSQ` requests. Rejected because sequential callers wait after each request, giving the protocol client a chance to release between calls.

## Decision: One-shot provider fields delegate through `withAcquired`

The N2C provider builds one handle implementation and uses it for both one-shot and acquired calls.

**Rationale**: This avoids two divergent implementations of era mismatch handling and query conversion.

**Alternatives considered**: Keep the current one-shot implementations and add separate handle implementations. Rejected because that duplicates query code and makes future provider fields easier to miss.
