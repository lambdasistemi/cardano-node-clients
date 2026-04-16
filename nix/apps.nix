{ pkgs, checks }:
builtins.mapAttrs (_: check: {
  type = "app";
  program = pkgs.lib.getExe check;
}) checks
