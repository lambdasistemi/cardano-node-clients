# haskell.nix overlay applying the WASM override set to a cabalProject'.
#
# For callers who prefer programmatic overlays over textual cabal.project fragments.
# Uses the same forks.json source of truth as cabal-project-fragment.nix.
#
# Applied via:
#   pkgs.haskell-nix.cabalProject' {
#     ...
#     modules = [ (import ./overrides.nix { inherit lib; }) ];
#   }
{ lib }:

let
  fragment = import ./cabal-project-fragment.nix { inherit lib; };
  forks = fragment.forks;

  pinToSRP = _name: pin: {
    src = builtins.fetchGit {
      url = pin.location;
      rev = pin.rev;
      # haskell.nix pinning: relies on the hash we already recorded in the
      # cabal.project fragment; builtins.fetchGit does its own content hashing.
    };
    subdirs = if pin.subdirs == [] then [ "." ] else pin.subdirs;
  };

  packageFlagsToModule = pkg: flagString:
    let
      # "+foo" -> { foo = true; }, "-bar" -> { bar = false; }
      sign = builtins.substring 0 1 flagString;
      flagName = builtins.substring 1 (-1) flagString;
      value = sign == "+";
    in {
      packages.${pkg}.flags.${flagName} = value;
    };

  packageGhcOptionsToModule = pkg: opts: {
    packages.${pkg}.ghcOptions = [ opts ];
  };
in
{ config, ... }: {
  # Documentation hook: record the override set in the module output so
  # downstream consumers can introspect what was applied.
  options.wasmOverrides = lib.mkOption {
    type = lib.types.attrs;
    default = forks;
    description = "Vendored fork pins applied by this overlay.";
  };

  config = lib.mkMerge (
    [
      # Fork pins as haskell.nix source-repository-package entries.
      {
        extraSources = lib.mapAttrsToList (name: pin: pinToSRP name pin) forks.pins;
      }
    ]
    ++ lib.mapAttrsToList packageFlagsToModule forks.packageFlags
    ++ lib.mapAttrsToList packageGhcOptionsToModule forks.packageGhcOptions
    ++ [
      {
        reinstallableLibGhc = false;
      }
    ]
  );
}
