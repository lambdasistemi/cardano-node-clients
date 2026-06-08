default:
    just --list

format:
    find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec fourmolu -i {} +
    cabal-fmt -i cardano-node-clients.cabal

hlint:
    find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec hlint {} +

build:
    cabal build cardano-node-clients:lib:cardano-node-clients cardano-node-clients:exe:utxo-indexer cardano-node-clients:exe:cardano-adversary -O0

e2e:
    cabal test e2e-tests -O0 --test-show-details=direct

unit:
    cabal test cardano-node-clients:unit-tests -O0 --test-show-details=direct

ci:
    just build
    just unit
    cabal-fmt -c cardano-node-clients.cabal
    find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec fourmolu -m check {} +
    find . -type f -name '*.hs' -not -path '*/dist-newstyle/*' -exec hlint {} +

serve-docs:
    mkdocs serve
