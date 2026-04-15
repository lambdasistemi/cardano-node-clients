# Feature Specification: Validate Preview node 10.7.0 compatibility

**Feature Branch**: `007-preview-node-1070`
**Created**: 2026-04-15
**Status**: Draft
**Input**: Issue #63

## User Scenarios & Testing

### User Story 1 - N2C E2E passes on the Preview-era node (Priority: P1)

As a maintainer of `cardano-node-clients`,
I want the local devnet harness to run on the same `cardano-node`
release currently used by Preview,
so that the N2C integration surface is checked against the current node behavior.

**Why this priority**: The repo’s primary integration contract is with a real node binary, so stale node pins reduce the value of the E2E suite.

**Independent Test**: Run the existing `e2e-tests` suite after updating the node pin to `10.7.0`.

**Acceptance Scenarios**:

1. **Given** the dev shell or devnet image uses `cardano-node` `10.7.0`,
   **When** the N2C provider and submission tests run,
   **Then** they pass without requiring mocked node behavior.

### User Story 2 - ChainSync path still passes on the Preview-era node (Priority: P1)

As a maintainer of `cardano-node-clients`,
I want the ChainSync-based E2E path to run successfully on `cardano-node` `10.7.0`,
so that the second protocol surface remains compatible with the current Preview node release.

**Why this priority**: The repo’s end-to-end confidence depends on both protocol paths, not just local state query and submission.

**Independent Test**: Run the existing ChainSync-related E2E cases after updating the node pin to `10.7.0`.

**Acceptance Scenarios**:

1. **Given** the devnet harness starts with `cardano-node` `10.7.0`,
   **When** the ChainSync E2E tests run,
   **Then** they complete successfully with the existing genesis and harness setup.

## Requirements

### Functional Requirements

- **FR-001**: The Nix dev shell MUST provide `cardano-node` `10.7.0`.
- **FR-002**: The standalone devnet Docker image MUST default to `cardano-node` `10.7.0`.
- **FR-003**: The flake lock MUST resolve the `cardano-node` input to the `10.7.0` release line.
- **FR-004**: The existing E2E suite MUST continue to run against a real local node with no mocked protocol layer.

## Success Criteria

### Measurable Outcomes

- **SC-001**: `just e2e` passes with the repo configured for `cardano-node` `10.7.0`.
- **SC-002**: No additional harness-specific compatibility patches are required beyond the version-alignment changes, or any required follow-up is documented.
