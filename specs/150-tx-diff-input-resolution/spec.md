# Feature Specification: Tx Diff Input Resolution

**Feature Branch**: `150-tx-diff-input-resolution`
**Created**: 2026-05-14
**Status**: Draft
**Input**: GitHub issue #150 and user discussion on opt-in input resolution
for `tx-diff`.

## User Scenarios & Testing

### User Story 1 - Resolve Spent Inputs Via Blockfrost (Priority: P1)

A `tx-diff` user passes `--resolve-web2 https://cardano-mainnet.blockfrost.io
--web2-api-key $BLOCKFROST_KEY` and the renderer shows, for each spending,
collateral, and reference input, the address, coin, datum, and reference
script of the output the input refers to. Spent UTxOs resolve too because
Blockfrost returns the historical transaction CBOR.

**Why this priority**: This is the practical capability the ticket asks for.
Reviewers diffing two pre-submission transactions on mainnet need the output
side of an input to interpret it; the production case is "what did this input
actually point to".

**Independent Test**: Run tx-diff against two CBOR transactions whose
spending inputs reference outputs from a known mainnet transaction. With the
flag set, the rendered diff shows each input's resolved address, coin, and
datum under the existing TxOut projection.

**Acceptance Scenarios**:

1. **Given** a transaction whose first input is `(txId, ix)` referring to a
   known historical UTxO, **When** tx-diff runs with the web2 flag and the
   API key, **Then** the tree under `body.inputs.0` contains the same shape
   as `body.outputs.0` (address, coin, datum, referenceScript).
2. **Given** two transactions that differ only in one input's resolved
   datum, **When** tx-diff runs with web2 resolution, **Then** the diff
   reports the datum change under that input's path.
3. **Given** the API call fails (bad key, network error, HTTP 404), **When**
   tx-diff runs, **Then** that input renders without resolution children and
   a single stderr line per failing input names the input and the resolver
   that failed.

### User Story 2 - Resolve Unspent Inputs Against A Local Node (Priority: P2)

A `tx-diff` user with a local cardano-node passes
`--resolve-n2c PATH --network-magic N` and the renderer resolves any input
whose UTxO is still unspent on the node's current tip.

**Why this priority**: Local devnet workflows already have a node socket; a
web2 round trip is wasteful and leaks transaction identifiers to a third
party.

**Independent Test**: Spin up a devnet node, place a known UTxO at a known
TxIn, and diff two transactions that consume that input. Tx-diff with the
N2C flag resolves the input from the node.

**Acceptance Scenarios**:

1. **Given** a TxIn that is unspent on the configured node, **When** tx-diff
   runs with the N2C flag, **Then** the rendered diff shows the resolved
   output under that input.
2. **Given** a TxIn that has already been spent on the configured node,
   **When** tx-diff runs with the N2C flag only, **Then** that input renders
   without resolution children and stderr reports it as unresolved by N2C.
3. **Given** the node socket is missing or the network magic is wrong,
   **When** tx-diff runs, **Then** the program emits a single startup error
   and exits non-zero before reading the transactions, so the user fixes the
   configuration rather than reading a misleading "unresolved" diff.

### User Story 3 - Preserve Offline Default (Priority: P1)

A `tx-diff` user who provides neither flag observes the exact same output as
today.

**Why this priority**: The ticket calls this out as a non-negotiable
default; existing CI users must not see any change.

**Independent Test**: Run the existing tx-diff unit suite without the new
flags. All current outputs remain byte-identical.

**Acceptance Scenarios**:

1. **Given** no resolver flag is set, **When** tx-diff runs against any
   existing fixture, **Then** every input renders exactly as today and no
   network call is made.
2. **Given** the input transaction has unusual shape (no inputs, only
   reference inputs, only collateral), **When** tx-diff runs offline,
   **Then** the rendered diff is unchanged from the current behavior.

### User Story 4 - Combine Web2 and N2C (Priority: P3)

A `tx-diff` user sets both `--resolve-web2` and `--resolve-n2c`. The renderer
tries N2C first for each input; for inputs N2C cannot resolve (already
spent), it falls back to web2.

**Why this priority**: Useful but secondary. The two flags need a defined
order so behavior is reproducible; both-set is reasonable for a developer
diffing a mainnet snapshot against a not-yet-submitted variant.

**Independent Test**: Diff two transactions where one input is currently
unspent (N2C resolves it) and another is already spent (only web2 resolves
it). Both render with resolution children.

**Acceptance Scenarios**:

1. **Given** both flags are set, **When** an input is unspent on the node,
   **Then** the diff is resolved without invoking the web2 call for that
   input.
2. **Given** both flags are set, **When** an input is spent on the node,
   **Then** the diff resolves it via web2.
3. **Given** both flags are set and both resolvers fail for one input,
   **When** tx-diff finishes, **Then** stderr names that input as
   unresolved by both resolvers and the diff continues with the other
   inputs.

### Edge Cases

- The same TxId appears in both transactions: web2 fetches it once and
  reuses the response. The first slice MAY skip caching if the network call
  is cheap; the spec only requires correctness.
- A resolver call hangs: an overall per-resolver timeout aborts that
  resolver, the failing inputs render unresolved, and tx-diff exits with the
  same code it would have produced offline.
- Resolution adds children to inputs that previously rendered atomically.
  Existing collapse-rules files that target `body.inputs.<i>` still work,
  because the rendered path of the TxIn changes from atomic to object only
  when resolution is enabled.
- Reference inputs and collateral inputs are treated the same as spending
  inputs: same resolver chain, same diagnostics, same diff shape.

## Requirements

### Functional Requirements

- **FR-001**: tx-diff MUST accept `--resolve-web2 URL` and
  `--web2-api-key KEY` flags that select Blockfrost-style transaction CBOR
  download for input resolution. `--web2-api-key` MAY be omitted if the URL
  needs no key.
- **FR-002**: tx-diff MUST accept `--resolve-n2c PATH` and
  `--network-magic N` flags that select a local cardano-node N2C resolver.
- **FR-003**: When no resolver flag is set, tx-diff MUST behave exactly as
  today.
- **FR-004**: When at least one resolver is set, tx-diff MUST attempt to
  resolve every `TxIn` in `body.inputs`, `body.referenceInputs`, and
  `body.collateralInputs` of both transactions.
- **FR-005**: A resolved input MUST attach the resolved Conway `TxOut` to
  the existing `TxIn` projection so the diff renderer descends into
  `address`, `coin`, `datum`, and `referenceScript` exactly as it does for
  body outputs.
- **FR-006**: An unresolved input MUST render without resolution children
  and MUST NOT fail the program. Tx-diff MUST emit at least one stderr line
  per unresolved input identifying the input and the resolver(s) that
  failed.
- **FR-007**: When both `--resolve-n2c` and `--resolve-web2` are set, the
  N2C resolver MUST be tried first; the web2 resolver MUST be tried only
  for inputs N2C did not resolve.
- **FR-008**: Resolver failure modes that prevent any input from being
  resolved (missing socket, bad network magic, missing/invalid Blockfrost
  URL) MUST fail at startup before the transactions are read, except for
  per-call network or HTTP errors which MUST be treated as per-input
  unresolved.
- **FR-009**: A web2 resolver MUST verify that the downloaded CBOR for a
  given `TxId` decodes as a Conway transaction, that the requested index
  exists in its outputs, and MUST treat any failure as unresolved for that
  input with a stderr diagnostic.
- **FR-010**: tx-diff MUST document the new flags, the privacy implication
  of sending transaction identifiers to a third-party web2 provider, and
  the requirement that the N2C resolver only sees currently-unspent UTxOs.

### Key Entities

- **Resolver**: A function `Set TxIn -> IO (Map TxIn (TxOut ConwayEra))` plus
  a name used in stderr diagnostics. The N2C resolver is the existing
  Provider's `queryUTxOByTxIn`. The web2 resolver downloads each referenced
  transaction by `TxId` and indexes into outputs by `TxIx`.
- **Resolution Mode**: The set of resolvers selected by CLI flags. May be
  empty, web2-only, n2c-only, or both. The order in "both" is fixed: N2C
  first.
- **Resolved Input**: A `(TxIn, TxOut ConwayEra)` pair used to feed the
  existing TxOut diff projection at the `TxIn` node.

## Success Criteria

### Measurable Outcomes

- **SC-001**: A transaction whose three input lists together contain N
  inputs renders, with both resolvers configured and all inputs unspent on
  N2C, with N resolved TxOut subtrees and zero web2 calls.
- **SC-002**: Running tx-diff against the existing unit fixtures with no
  resolver flags produces byte-for-byte identical output to current main.
- **SC-003**: An input that fails all configured resolvers produces exactly
  one stderr diagnostic identifying the input by `txId#ix` and the resolvers
  that failed, and tx-diff continues to render the rest of the diff.
- **SC-004**: A web2 round trip per input is bounded by one HTTP GET that
  returns a CBOR-encoded transaction; the implementation does not
  recursively follow references or fetch protocol parameters.

## Assumptions

- Blockfrost-compatible providers expose `GET /txs/{hash}/cbor` returning
  `{"cbor":"<hex>"}` or equivalent that decodes to a Conway transaction.
  Providers that diverge from this contract are out of scope for the first
  slice and may be added later behind the same flag with explicit handling.
- Inputs reference Conway transactions only. Pre-Conway eras are out of
  scope for the resolver in this slice; the existing tx-diff core is
  Conway-only.
- The user understands that web2 download reveals transaction identifiers
  to the configured provider; the spec only requires this be documented,
  not redacted.
- The N2C resolver targets a local node owned by the user; this is the
  same trust model as the existing Provider code in this repository.

## Out Of Scope

- Submitting transactions, mutating chain state, or driving block
  production.
- Making web2 and N2C return semantically identical results beyond
  "resolved TxOut or not resolved".
- Caching across runs or across process lifetimes; the first slice MAY
  deduplicate within one run but does not promise it.
- Alternative web2 providers whose API does not match the Blockfrost CBOR
  contract.
- New blueprint behavior. Resolved datums use the same blueprint decoder
  as today via `--blueprint`.
