# Data Model: TxBuild self-validates against ledger Phase-1

**Branch**: `153-txbuild-integrity-hash` | **Date**: 2026-05-15

TxBuild is a pure assembly layer; there is no persisted
state to model. The "data model" for this feature is the
small set of types we introduce or extend so that the
invariants in [spec.md](./spec.md) can be enforced
structurally.

---

## E-1 `PParamsBound era` (NEW, internal-only)

**Shape** (provisional, settled by R-004):

```haskell
newtype PParamsBound era = PParamsBound
  { unPParamsBound :: PParams era }
```

**Construction**: smart constructor exposed only at the
build entrypoint (e.g. `runBuild :: PParams era -> … ->
m (Either (Check e) (Tx era))`). Once inside the
build, only the `PParamsBound` value is passed around.

**Invariant**: every internal helper that depends on
protocol parameters (fee estimation, exec-units
estimation, integrity-hash computation, self-validation)
accepts `PParamsBound era`, not raw `PParams era`. This
enforces FR-002 at the type level.

**Why a newtype, not a Reader monad**: TxBuild's
monad is already an operational `TxBuild` interpreted
by `draft`/`build`/`InterpretIO`; adding a reader
layer is intrusive. A newtype is cheap, local, and
gives the same "one source of truth" guarantee.

**Status**: contingent on R-004 — if the audit shows
`PParams` is already threaded as one argument, the
newtype may be skipped in favor of a comment + a
property-style audit test. Either path satisfies the
spec.

---

## E-2 `LedgerCheck` (EXTEND)

**Today** (`TxBuild.hs:305`):

```haskell
data LedgerCheck
  = MinUtxoViolation Word32 Coin Coin
  | TxSizeExceeded Natural Natural
  | ValueNotConserved MaryValue MaryValue
  | CollateralInsufficient Coin Coin
```

**After**:

```haskell
data LedgerCheck era
  = MinUtxoViolation Word32 Coin Coin
  | TxSizeExceeded Natural Natural
  | ValueNotConserved MaryValue MaryValue
  | CollateralInsufficient Coin Coin
  | Phase1Rejected (ApplyTxError era)
```

`Check e` (`TxBuild.hs:295`) gains the same `era`
parameter where needed.

**Migration**: every constructor of the existing
enum stays — we add `Phase1Rejected`, we do not
delete anything in this PR. Some existing
constructors may be subsumed by `Phase1Rejected`
on a future cleanup; that follow-up is out of scope
(per `feedback_destructive_api_mutations`).

---

## E-3 Language-set derivation (helper, internal)

**Shape** (provisional, settled by R-003):

```haskell
languagesUsedInBody
  :: TxBody ConwayEra
  -> UTxO ConwayEra
  -> Set Language
```

**Behavior**: walks (a) the body's spending redeemers and
their resolved scripts, (b) any reference-script inputs
that supply a Plutus script, and returns the set of
`Language` values actually used. Native (timelock) scripts
do not contribute.

**Usage**: feeds `computeScriptIntegrity` instead of the
current single-`Language` argument. Tying the language
set to the body — not to caller intent — is the FR-001
fix.

---

## E-4 `computeScriptIntegrity` (CHANGE signature)

**Today** (`Scripts.hs:84`):

```haskell
computeScriptIntegrity
  :: Language
  -> PParams ConwayEra
  -> Redeemers ConwayEra
  -> StrictMaybe ScriptIntegrityHash
```

**After**:

```haskell
computeScriptIntegrity
  :: Set Language
  -> PParamsBound ConwayEra            -- or PParams ConwayEra, per R-004
  -> Redeemers ConwayEra
  -> TxDats ConwayEra                  -- witness-set datums
  -> StrictMaybe ScriptIntegrityHash
```

The witness-set datums argument replaces the hard-coded
`TxDats mempty`; even though the issue-#153 tx has no
datums, hard-coding `mempty` is the same caller-trust
footgun as hard-coding the language.

---

## E-5 No persistent entities

The remaining "entities" listed in the spec — script
integrity hash, language view, Conway redeemers,
`PParams` instance, Phase-1 validation — are all
ledger-defined types. We import, we don't redefine.

---

## Cross-cutting invariants

(These are the same as the spec's FRs; restated here as
data-model contracts.)

- *Single `PParams` instance.* For a given build call,
  exactly one `PParams era` value flows in through the
  smart constructor; every internal type that
  references protocol parameters is parameterized over
  the same value.
- *Body-derived language set.* The language set used in
  the integrity-hash computation is derived from the
  body, not provided by the caller.
- *Phase-1 result decides return type.* The build call
  returns `Right (Tx era)` iff
  `applyTx pp utxo slot tx == Right _`; otherwise it
  returns `Left (LedgerFail (Phase1Rejected err))`.
