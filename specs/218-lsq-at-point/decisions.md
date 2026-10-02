# Decisions and reasons

| Decision | Reason |
| --- | --- |
| Add `withAcquiredLSQAt`, returning `Either AcquireFailure a`. | Preserves existing signatures and exposes node refusals as ordinary typed outcomes. Transport and callback exceptions retain their existing meaning. |
| Add a separate point request; preserve `LSQAcquire`. | Public request constructors are exported; changing their arity would break consumers. |
| Reuse the acquired handle and query loop. | All callback queries then share one acquisition, with the existing queue and release discipline. |
| Preserve the existing volatile path, including failure handling. | The ticket explicitly preserves tip behavior; broad failure-policy repair is outside this change. |
| Check caller cancellation at every new lifecycle blocking point. | Masking can still permit interruption at blocking operations; caller outcomes and subsequent channel progress must detect an abandoned acquisition, including late success. |
| Keep the legacy cancellation source lead unproved and outside repair scope. | Source inspection does not establish a live bug; the new path must meet its lifecycle checks while existing tip behavior remains unchanged. |
| Require a controlled state change before acquisition and another afterward. | A tip fallback can pass a later-motion test if P was tip at acquisition. Different observed UTxO contents make the fallback detectable. |
| Observe and submit on an independent connection. | The subject's LSQ loop cannot serve an observer while its acquired callback is active. |
| Slow only the recent witness's private genesis to one-second slots. | k=10 at 0.1-second slots gives little transaction coordination time. Block retention and shared devnet defaults remain intact. |
| Use a genuine aged block and observe the immutable anchor. | k counts blocks, not slots; the anchor remains available. An ancient fabricated hash cannot prove the requested old on-chain behavior. |
| Choose the unknown point's slot above the anchor. | The pinned backend returns TooOld for missing points below the anchor, even with unknown hashes. |
| Use existing unit/e2e CI entry points. | New cases are automatically executed by the established jobs once registered; no second acceptance oracle or new CI job is necessary. |
| Document snapshot pairing at the low-level LSQ API. | #218 requires an additive library session; expanding Provider or indexer historical reads would enlarge the contract. |

## Reliance declaration

All rows are **BLOCKING**; intake enforcement is **NONE**. These are named
implementation dependencies, not claims that this planning commit proves them.

| Dependency | Relied-on truth | Future enforcement / honest limit |
| --- | --- | --- |
| Node protocol and ledger | Successful SpecificPoint acquisition retains the state for its query lifetime; named errors come from the node. | Real devnet P-state/refusal cases. Pinned source inspection is guidance only. |
| Channel lifecycle | The new path can use existing timeout/generation infrastructure while ensuring cancellation-safe acquisition and cleanup; masking alone is not assumed sufficient. | Planned enqueue/acknowledgement/callback/release barriers, caller outcomes and subsequent query success, including late acknowledgement; exception, stall, disconnect and refusal checks plus existing tip suites. Safety remains unproved until executed; legacy repair needs separate authority. |
| Snapshot producer | `readView` / `read_view` binds all results to its reported slot/hash and materializes current state. | Existing indexed-view/socket tests and fault jobs; examples preserve the exact pair. This ticket does not reimplement the producer. |
| Devnet witness | Controlled transactions are included and selected block/anchor observations are independent of the subject API. | Runtime inclusion, contents and ordering assertions; setup failure cannot count as behavior evidence. |
