# Tasks — Issue 190: stock devnet committee arrangement

## Slice A — Stock genesis fix + enactment proof
- [X] T190-SA1 Patch `e2e-test/genesis/conway-genesis.json`: one CC committee member, `committeeMinSize: 7 -> 1`, field-by-field enumerated.
- [X] T190-SA2 Expose/add key material and cert/vote helpers a consumer needs for CC hot-key authorization + committee voting (mirror #187's `Governance.hs` pattern).
- [X] T190-SA3 Add and pass a live E2E test: propose + vote + assert enactment of a real `ParameterChange` on a fresh stock `withDevnet` devnet, via queried protocol-parameters.
