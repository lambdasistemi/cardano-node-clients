# haskell.nix module — native build: point pkg-config at nixpkgs libsodium-vrf,
# secp256k1, libblst, lmdb, liburing; silence Haddock for packages that
# consistently fail it.
{ lib, pkgs, ... }:
{
  packages.cardano-crypto-praos.components.library.pkgconfig =
    lib.mkForce [ [ pkgs.libsodium-vrf ] ];
  packages.cardano-crypto-class.components.library.pkgconfig =
    lib.mkForce [ [ pkgs.libsodium-vrf pkgs.secp256k1 pkgs.libblst ] ];
  packages.cardano-lmdb.components.library.pkgconfig =
    lib.mkForce [ [ pkgs.lmdb ] ];
  packages.blockio-uring.components.library.pkgconfig =
    lib.mkForce [ [ pkgs.liburing ] ];
  packages.cardano-ledger-binary.components.library.doHaddock =
    lib.mkForce false;
  packages.plutus-core.components.library.doHaddock = lib.mkForce false;
  packages.plutus-ledger-api.components.library.doHaddock = lib.mkForce false;
  packages.plutus-tx.components.library.doHaddock = lib.mkForce false;
}
