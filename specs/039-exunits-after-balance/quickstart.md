# Quickstart: Balance-Aware ExUnits

1. Run the focused unit tests:

   ```bash
   cabal test unit-tests -O0 --test-options='--match "/TxBuild/"'
   ```

2. Run the repository local CI equivalent:

   ```bash
   just ci
   ```

3. Run the CI-parity Nix gate:

   ```bash
   nix build --quiet .#checks.x86_64-linux.build .#checks.x86_64-linux.e2e .#checks.x86_64-linux.lint
   ```
