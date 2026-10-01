# Functions model — 197

| ID | Name | Signature | Notes |
|---|---|---|---|
| F-1 | `withRestartableNode` | `FilePath -> (RestartableNode -> IO a) -> IO a` | new; argument `srcGenesis` as today |
| F-2 | `RestartableNode` | record: `nodeSocket :: FilePath`, `nodeStartMs :: Integer`, `nodeRunDir :: FilePath`, `nodeDbDir :: FilePath`, `restartNodeWith :: IO () -> IO ()` | new, exported with fields; argument of `restartNodeWith` is the hook |
| F-3 | `withRestartableCardanoNode` | `FilePath -> (FilePath -> Integer -> IO () -> IO a) -> IO a` | byte-identical; defined via F-1 |
| F-4 | `withCardanoNode` | `FilePath -> (FilePath -> Integer -> IO a) -> IO a` | byte-identical |

Internal helpers in `Devnet.hs` are the commit owner's choice.
