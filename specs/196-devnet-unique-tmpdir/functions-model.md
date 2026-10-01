# Functions model — 196

No new exported functions. Signatures that MUST remain byte-identical:

| ID | Function | Signature |
|---|---|---|
| F-1 | `withCardanoNode` | `FilePath -> (FilePath -> Integer -> IO a) -> IO a` |
| F-2 | `withRestartableCardanoNode` | `FilePath -> (FilePath -> Integer -> IO () -> IO a) -> IO a` |
| F-3 | `withDevnet`, `withDevnetConfig`, `withDevnetFromGenesis` | unchanged (`Setup.hs` untouched) |

Internal helpers in `Devnet.hs` are the commit owner's choice; `prepareTmpDir`
may change shape. Arguments: `srcGenesis` is the genesis source directory,
never written.
