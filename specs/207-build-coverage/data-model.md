# Data model — #207

Extends #202 DM11. No existing key or encoding changes.

## DM12 Build-coverage record, in `MetaCol`

Key (ASCII) `build-coverage`. Value, version 1, all integers big-endian:

| Part | Bytes |
|---|---|
| version | `0x01` |
| start | `0x00` origin, or `0x01` · slot u64 · hash length u32 · hash bytes |
| interest | `0x00` all, or `0x01` · count u32 · per address in ascending byte order: length u32 · bytes |

No trailing bytes. Any other value is undecodable (V7).

## Store coverage outcome (per follower bracket)

- **BuildCoverage** — start: none or (slot, block hash); interest set.
  Equality is exact (address set equality).
- **StoreCoverage** — recorded (a BuildCoverage) | unrecorded.
- **BuildCoverageRefusal** — mismatch (recorded, requested) |
  undecodable (raw bytes, requested).

| Store | Record | Outcome | Writes |
|---|---|---|---|
| empty, full families | absent | recorded (requested) | record |
| any | equal | recorded | none |
| any | different | refusal mismatch | none |
| any | undecodable | refusal undecodable | none |
| non-empty | absent | unrecorded | none |
| degraded | — | unrecorded | none |

## Wire coverage (C1 values added)

- start: origin | point | **unknown**; addresses: all | filtered |
  **unknown**. Unrecorded → both unknown. Recorded → derived as #201 J2
  from the record.
- Limit **coverage_unknown**, first in order.
