# Phase 1 (FOD) of the two-phase WASM build pattern.
#
# Bootstraps cabal's package cache from the truncated Hackage index,
# producing a store path that a later offline derivation can mount as
# CABAL_DIR. This is the pattern documented in the haskell-wasm skill
# (see paolino/cardano-addresses branch 001-wasm-target for the reference).
{ pkgs, lib, index ? null }:

let
  truncated = import ./truncated-index.nix { inherit pkgs lib; };
  hackageIndex = if index == null then truncated.hackage else index;
  name = "cabal-bootstrap-hackage";
in
pkgs.runCommand name {
  nativeBuildInputs =
    [ pkgs.haskell-nix.nix-tools.exes.cabal ]
    ++ pkgs.haskell-nix.cabal-issue-8352-workaround;
} ''
  HOME=$(mktemp -d)
  mkdir -p $HOME/.cabal/packages/hackage.haskell.org

  cat > $HOME/.cabal/config <<EOF
  repository hackage.haskell.org
    url: file:${pkgs.haskell-nix.mkLocalHackageRepo { name = "hackage.haskell.org"; index = hackageIndex; }}
    secure: True
    root-keys: aaa
    key-threshold: 0
  EOF

  cabal v2-update hackage.haskell.org

  cp -rL $HOME/.cabal/packages/hackage.haskell.org $out
  chmod -R u+w $out
''
