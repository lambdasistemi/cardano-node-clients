# Plan (#198)

## Strategy

One slice, OWNER topology. Textual, local edits in
`lib/Cardano/Node/Client/UTxOIndexer/Follower.hs` at the sites below,
one unit check, one docs subsection. Keep the diff local so rebases
against concurrent indexer work (#205, #206) stay trivial.

## Sites (base `5e038a5`)

- `csStartPoint` field Haddock (~L216).
- `BootMode` Haddock (~L715–727).
- `coldBootResumePoints` Haddock (~L748).
- `WarmBoot` branch of `intersectNotFound` (~L794–810).
- `docs/usage/utxo-indexer.md`, near "Embedded use".
- Unit check: `test/Cardano/Node/Client/UTxOIndexer/FollowerSpec.hs`
  or a sibling spec registered in `test/unit-main.hs`.

## Constraints

- The fail-closed decision stays an exception raised only on the
  warm path; the cold path still retries with `coldBootResumePoints`.
- Existing exported signatures unchanged. An additive export needed
  to observe the message is allowed and must carry Haddock.

## Slices

- **S1** — R1–R7 (tasks T001–T004).
