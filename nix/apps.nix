{ pkgs, scripts }:
builtins.mapAttrs (_: script: {
  type = "app";
  program = pkgs.lib.getExe script;
}) scripts
