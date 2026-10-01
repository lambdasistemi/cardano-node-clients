# Functions model (#198)

- **F1** (optional, owner's choice) — one additive exported value in
  M1 carrying the warm-boot no-intersection message, used by the
  `WarmBoot` branch of `intersectNotFound` and by the R7 check.
  Signature-level constraint: a pure value; no change to
  `intersectNotFound`'s type or to any existing export.
