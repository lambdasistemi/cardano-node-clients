# Renders the `if arch(wasm32)` cabal.project stanza from forks.json.
#
# Consumers can either:
#   (a) splice the rendered string into their own cabal.project, or
#   (b) pass it as cabalProjectLocal to cabalProject'.
#
# Source of truth for revs and hashes: ./forks.json. Do not duplicate them here.
{ lib }:

let
  forks = builtins.fromJSON (builtins.readFile ./forks.json);

  renderSubdirs = subdirs:
    if subdirs == [] then ""
    else "    subdir:\n" + lib.concatMapStrings (s: "      ${s}\n") subdirs;

  renderPin = name: pin: ''
    source-repository-package
      type: git
      location: ${pin.location}
      tag: ${pin.rev}
  ${renderSubdirs pin.subdirs}  --sha256: ${pin.sha256}
  '';

  renderFlags = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (pkg: flags: ''
      package ${pkg}
        flags: ${flags}
    '') forks.packageFlags
  );

  renderGhcOptions = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (pkg: opts: ''
      package ${pkg}
        ghc-options: ${opts}
    '') forks.packageGhcOptions
  );

  renderConstraints =
    if forks.constraints == [] then ""
    else "constraints: " + lib.concatStringsSep ", " forks.constraints;

  renderAllowNewer =
    if forks.allowNewer == [] then ""
    else "allow-newer: " + lib.concatStringsSep ", " forks.allowNewer;
in
{
  # Full stanza wrapped in `if arch(wasm32)` — for splicing into an existing cabal.project
  # that builds for both native and wasm32 targets.
  stanza = ''
    if arch(wasm32)
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderPin forks.pins)}

    ${renderFlags}

    ${renderGhcOptions}

      ${renderConstraints}
      ${renderAllowNewer}
  '';

  # Bare body — for callers that pass this via cabalProjectLocal inside
  # a project that is exclusively wasm32.
  body = ''
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList renderPin forks.pins)}

    ${renderFlags}

    ${renderGhcOptions}

    ${renderConstraints}
    ${renderAllowNewer}
  '';

  inherit forks;
}
