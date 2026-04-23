# Deterministic Hackage / CHaP index snapshot derivations.
#
# Phase 1 of the two-phase FOD pattern (see ../haskell-wasm skill).
# Produces a truncated index tarball pinned to the date in forks.json.
#
# This isolates the non-determinism of `cabal update` from the WASM compile phase.
{ pkgs, lib, indexState ? null }:

let
  forks = builtins.fromJSON (builtins.readFile ./forks.json);
  hackageIndexState = if indexState == null then forks.indexState.hackage else indexState;
  chapIndexState = forks.indexState.chap;

  hackageHashes = import pkgs.haskell-nix.indexStateHashesPath;
  hackageHash = hackageHashes.${hackageIndexState} or (throw ''
    Hackage index-state ${hackageIndexState} has no pinned hash in haskell.nix's
    indexStateHashesPath. Bump haskell.nix or choose a different date.
  '');

  truncateIndex = name: url: state: hash: pkgs.fetchurl {
    inherit url;
    downloadToTemp = true;
    postFetch = ''
      ${pkgs.haskell-nix.nix-tools}/bin/truncate-index \
        -o $out \
        -i $downloadedFile \
        -s '${state}'
    '';
    outputHashAlgo = "sha256";
    outputHash = hash;
  };
in
{
  hackage = truncateIndex
    "hackage-truncated"
    "https://hackage.haskell.org/01-index.tar.gz"
    hackageIndexState
    hackageHash;

  # CHaP index is truncated the same way; the caller records its hash in
  # forks.json (not yet populated — computed on first run via:
  #   nix run github:input-output-hk/haskell.nix#truncate-index -- \
  #     -i chap-01-index.tar.gz -o out.tar.gz -s '<state>'
  #   sha256sum out.tar.gz
  # ).
  chap = {
    # Placeholder until the CHaP hash is recorded in forks.json.
    # The overlay path in overrides.nix handles CHaP via haskell.nix's
    # cabalProject' `inputMap`; this entry is a future-proofing hook.
    indexState = chapIndexState;
  };

  inherit hackageIndexState chapIndexState;
}
