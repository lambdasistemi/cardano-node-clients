# Validity — horizon-aware upper-bound slot

`Cardano.Node.Client.Validity` picks an `invalid-hereafter` slot
that is guaranteed to survive Plutus context translation. It is the
solution to a class of bugs where a builder picks `tip + N hours`,
hands the unsigned tx to a signer, and the signer (or the node) hits
`TimeTranslationPastHorizon` deep inside script evaluation.

## What "horizon" means

The Cardano chain is divided into **epochs** (mainnet: 432 000 slots
= 5 days). Consecutive epochs sharing the same consensus rules form
an **era** (Conway is the current era). At any epoch boundary the
protocol may **hard-fork** to a new era with new parameters,
including a new slot length.

The consensus layer can translate a slot to a `UTCTime` only as far
as its **horizon**: typically the end of the current era, plus the
era's **safe zone** when the chain is close enough to that boundary
that no further hard fork could be announced. Plutus script context
needs this translation for any transaction whose validity interval
references slots — so a tx built with an upper bound past the
horizon is silently un-evaluatable.

`queryUpperBoundSlot` always returns slots that are inside the
horizon (or refuses, depending on the choice).

## API

```haskell
import Cardano.Node.Client.Validity
  ( ValidityChoice (..)
  , HorizonError (..)
  )
import Cardano.Node.Client.Provider (Provider (..))
```

Three modes:

* **`AutoLongest`** — pick the largest slot inside the horizon. The
  result is mid-epoch-conservative: it equals the current era's end
  slot when the chain is far from a boundary, and extends by the
  safe zone when close to it (mirroring how the consensus layer
  itself updates its summary). For testnets / devnets where the
  last era is unbounded, `AutoLongest` returns `tip + one year of
  slots` — effectively unlimited.

* **`MaxHours N`** — pick `min(tip + N*3600, horizon)`. Use when
  internal policy caps signing windows below the chain horizon
  ("we never sit on an unsigned tx for more than 24 h").

* **`ExactlyHours N`** — require exactly `tip + N*3600` to be inside
  the horizon; otherwise return `Left HorizonError` with the
  requested slot, the horizon slot, the tip, and the requested
  hours so the caller can render a helpful diagnostic.

## Worked example — mainnet mid-epoch

Tip slot `S` is 60 000 slots before the era end. Safe zone is 129 600.
`AutoLongest` returns the era end minus 1 — about 16.6 hours from
tip. `MaxHours 4` returns `S + 14 400`, since 4 h is comfortably
inside the horizon. `ExactlyHours 24` returns
`Left (HorizonError requested horizon tip 24)`: the request
overshoots by ~7.4 h.

The same call inside the safe zone (≤ 36 h from era end) typically
returns a slot up to ~5 days further out, because the consensus
interpreter has updated its summary with the next-era parameters and
the horizon has moved.

## When to use which

| Caller intent | Choice |
|---|---|
| "Give me the most permissive submission window the chain allows." | `AutoLongest` |
| "Cap my window at policy N hours, regardless of chain headroom." | `MaxHours N` |
| "I committed to N hours; surface the chain-side mismatch loudly." | `ExactlyHours N` |

## Implementation note

The math drives the consensus `Interpreter` through its public
`interpretQuery` API only — no `Codec.Serialise` round-trip and no
`unsafeCoerce` reach into the wrapped `Summary`. The `AutoLongest`
search converges in ≈ 20 probes of `slotToWallclock` (binary search
over `tip .. tip + 1 year`).
