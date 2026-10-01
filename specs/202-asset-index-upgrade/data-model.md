# Data model — #202 (C2 versioning)

Extends #200's DM1–DM10. No existing encoding changes.

## DM11 Asset-index state, in `MetaCol`

| Key (ASCII) | Value | Meaning |
|---|---|---|
| `asset-index` | `0x01` | complete (unchanged from #200) |
| `asset-index-rebuild` | progress bytes (owner's encoding, versioned by a leading byte) | an upgrade is in progress |

States, decided in one read transaction:

| State | Families | `asset-index` | `asset-index-rebuild` | Asset query |
|---|---|---|---|---|
| DEGRADED | 4 | — | — | `absent` |
| ABSENT | 6 | absent | absent | `absent` |
| REBUILDING | 6 | absent | present | `rebuilding` |
| COMPLETE | 6 | present | absent | #200 behaviour |

- Both keys present is never written by any transaction.
- DEGRADED → (request) → REBUILDING; ABSENT → (request) → REBUILDING;
  REBUILDING → COMPLETE on finish; REBUILDING → ABSENT on an extraction
  failure (U10); REBUILDING persists across close/open and resumes.
- COMPLETE and an empty store ignore the request (U9).
- Only `AssetIndex` and `MetaCol` rows change in these transitions (U6).

## Unavailability

`AssetQueryUnavailable` gains `AssetIndexRebuilding`; wire reason
`rebuilding`. Precedence: rebuilding, then absent, then #200's order.
