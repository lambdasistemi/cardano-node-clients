# tx-diff

`tx-diff` compares two encoded Conway transactions and prints structural
differences.

Install released builds:

```bash
# macOS
brew tap lambdasistemi/tap
brew install tx-diff
```

Linux users can download `tx-diff-<version>-x86_64-linux.AppImage`,
`.deb`, or `.rpm` from the
[GitHub Releases](https://github.com/lambdasistemi/cardano-node-clients/releases)
page.

Use the main documentation for the executable manual, tutorials, collapse-rule
YAML, blueprint behavior, exit codes, and troubleshooting:

- [tx-diff manual](../../docs/executables/tx-diff.md)
- [TxDiff architecture](../../docs/modules/tx-diff.md)

Quick command:

```bash
tx-diff --collapse-rules collapse.yaml --blueprint plutus.json tx-a.cbor tx-b.cbor
```
