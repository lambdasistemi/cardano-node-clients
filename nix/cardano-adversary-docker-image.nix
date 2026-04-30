{ pkgs, components, imageTag, ... }:
let
  # /usr/bin/env so any composer / driver shebang like
  # `#!/usr/bin/env bash` resolves inside the container.
  usrBinEnv = pkgs.runCommand "usr-bin-env" { } ''
    mkdir -p $out/usr/bin
    ln -s ${pkgs.coreutils}/bin/env $out/usr/bin/env
  '';
in
pkgs.dockerTools.buildImage {
  name = "ghcr.io/lambdasistemi/cardano-node-clients/cardano-adversary";
  tag = imageTag;

  # Single-purpose image: the daemon is the entrypoint;
  # the consumer (e.g. the cardano-node-antithesis testnet's
  # docker-compose.yaml) supplies the CLI flags and may mount
  # composer scripts at /opt/antithesis/test/v1/adversary/.
  config = {
    EntryPoint = [ "/bin/cardano-adversary" ];
    Labels = {
      "org.opencontainers.image.documentation" =
        "https://github.com/lambdasistemi/cardano-node-clients/blob/main/specs/036-cardano-adversary/contracts/control-wire.md";
    };
  };

  # buildEnv collects the binary's full nix closure into
  # /nix/store inside the image. netcat-openbsd is included
  # so composer scripts can shell into the container and talk
  # to the control socket via `nc -U`.
  copyToRoot = pkgs.buildEnv {
    name = "cardano-adversary-image-root";
    paths = [
      pkgs.coreutils
      pkgs.bash
      pkgs.jq
      pkgs.gnugrep
      pkgs.netcat-openbsd
      usrBinEnv
      components.exes.cardano-adversary
    ];
  };
}
