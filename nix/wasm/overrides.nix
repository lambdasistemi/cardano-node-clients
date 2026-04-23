# haskell.nix module hook for WASM-specific overrides.
#
# Per-package flags and ghc-options are already embedded in the cabal.project
# fragment (cabal-project-fragment.nix) via `package X { flags/ghc-options }`
# stanzas, so cabal honors them without needing a haskell.nix module echo.
#
# This module is retained as a hook so future per-package haskell.nix-level
# overrides (build tools, patches, postInstall scripts, etc.) have a home.
# Today it is a no-op.
{ lib }:

{ config, ... }: {}
