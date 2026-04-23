module Main (main) where

import WasmSmoke (smokeRoundTrip)

main :: IO ()
main = case smokeRoundTrip 42 of
    Right 42 -> putStrLn "cborg round-trip OK"
    Right n  -> putStrLn ("cborg round-trip unexpected value: " ++ show n)
    Left err -> putStrLn ("cborg round-trip failed: " ++ err)
