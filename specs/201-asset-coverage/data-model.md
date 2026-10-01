# Data model — #201

## Disclosure (fixed per serving process)

- **DD1 Coverage** — start: origin or a concrete (slot, block hash);
  addresses: all or filtered. Derived from the follower configuration
  (no start point → origin; `IndexAll` → all; `IndexAddressSet` →
  filtered).
- **DD2 Disclosure** — network magic (32-bit), coverage, ready
  threshold in slots (the `ready` threshold), stale bound (seconds,
  positive).

## Freshness (per answer, derived)

- **DD3 FreshnessStatus** — synced | catching_up | disconnected |
  stale; precedence and rules in spec.md.
- **DD4 Freshness** — status, tip slot (optional), slots behind the
  answer's point (optional, clamped at 0), seconds since last progress
  (non-negative, whole seconds).
- **DD5 Limit** — address_filter | partial_history | catching_up |
  disconnected | stale; the answer carries the J4 set in that order.

## ReadyStatus

- **DD6** gains last progress: the follower readiness write time
  (roll-forward applied or upstream status change). Not on the wire of
  `ready`.

## State invariants

- Disclosure never changes while the server runs.
- Freshness is computed after the snapshot read, from the snapshot's
  point, one readiness sample and one clock sample.
