# Changelog

## 0.1.0.0

- Initial release
- N2C LocalStateQuery and LocalTxSubmission clients
- Provider and Submitter record-of-functions interfaces
- Transaction balancing utilities

## Unreleased

## [0.1.4.1](https://github.com/lambdasistemi/cardano-node-clients/compare/v0.1.4.0...v0.1.4.1) (2026-07-11)

### Bug Fixes

* **n2c:** recover LSQ callers from connection loss ([2726c00](https://github.com/lambdasistemi/cardano-node-clients/commit/2726c00029007b749da61d2ec585d22af4ee0c7b))

## [0.1.4.0](https://github.com/lambdasistemi/cardano-node-clients/compare/v0.1.3.0...v0.1.4.0) (2026-07-10)

### Features

* **utxo-indexer:** factor withChainSyncFollower out of runDaemon ([5844654](https://github.com/lambdasistemi/cardano-node-clients/commit/5844654564a30b58ae48ec3ea22ddac8a512b4af))
* **utxo-indexer:** interest-set address filter on withChainSyncFollower ([daaad88](https://github.com/lambdasistemi/cardano-node-clients/commit/daaad8853c22230e795995b1a4fceba58c392798))
* **utxo-indexer:** csStartPoint on ChainSyncConfig honors cold-boot intersection ([0e73121](https://github.com/lambdasistemi/cardano-node-clients/commit/0e73121dc1df516b69d69bdd554b12bebd28d072))
* **utxo-indexer:** expose chain-sync block + tip tracers on withChainSyncFollower ([540c34e](https://github.com/lambdasistemi/cardano-node-clients/commit/540c34e927fa308f81e014d34634e0ca9bb5452d))
* **utxo-indexer:** chain-follower Runner wrapper for tip-distance phase ([bc0fb96](https://github.com/lambdasistemi/cardano-node-clients/commit/bc0fb96fbe1ff7ee024c17aa8fb04c1bfe7976ef))
* **utxo-indexer:** port Byron block extraction from cardano-utxo-csmt ([6f7527b](https://github.com/lambdasistemi/cardano-node-clients/commit/6f7527b0b9e163088fe0586a35c074e6e481fb9f))
* **utxo-indexer:** add ChainSyncConfig handler list ([60c1d89](https://github.com/lambdasistemi/cardano-node-clients/commit/60c1d89ec83063954343aa815bce06ab46c7b1b3))
* **utxo-indexer:** use ChainSyncConfig handlers ([e380cbe](https://github.com/lambdasistemi/cardano-node-clients/commit/e380cbecb3bb329764ffe5b03f7d0dcd44725938))
* **utxo-indexer:** add typed provider modes ([1e56206](https://github.com/lambdasistemi/cardano-node-clients/commit/1e56206817a21a8483db540ff46df99909d22476))
* **utxo-indexer:** expose indexer transaction runner ([4986c3f](https://github.com/lambdasistemi/cardano-node-clients/commit/4986c3fcc1bd59199158328ffb0e32763790f6de))
* **tx-history:** add tenant-prefixed history storage ([89d5d61](https://github.com/lambdasistemi/cardano-node-clients/commit/89d5d61cf6b3d5ffe73d97b48ea75d06008d6624))
* **tx-history:** share chain-sync with history indexing ([06e0733](https://github.com/lambdasistemi/cardano-node-clients/commit/06e07334ef153e8aa724ea59901b5d1863780980))
* **tx-history:** add detailed transaction lookup ([a42c597](https://github.com/lambdasistemi/cardano-node-clients/commit/a42c5977685e5846a02692aeb4f86e51b77ce965))
* **tx-history:** store transaction direction ([4339657](https://github.com/lambdasistemi/cardano-node-clients/commit/43396575397486aff8e37b1164b0c45f887b03d8))
* **adversary:** land N2N adversary module (PV12/Dijkstra-capable) (#179) ([76ae585](https://github.com/lambdasistemi/cardano-node-clients/commit/76ae585019cd239f3f43dbec55ea4af36b8cd0cd))

### Bug Fixes

* **utxo-indexer:** skip Byron EBBs in the apply path ([30c8869](https://github.com/lambdasistemi/cardano-node-clients/commit/30c88698604c77e54d8d701129a3d13db472efe3))
* **N2C:** import Data.List.foldl' for May-stack build ([1f869d6](https://github.com/lambdasistemi/cardano-node-clients/commit/1f869d6e90551cd733d26c829d7b8e90fe317b18))
* **N2C:** qualify foldl' import for May stack (#175) ([0f44f49](https://github.com/lambdasistemi/cardano-node-clients/commit/0f44f49c6d7ecf84e8e93750a3bcd9987310690e))
* **tx-history:** pass block slot to history decoder ([cdcdab2](https://github.com/lambdasistemi/cardano-node-clients/commit/cdcdab2ba3bc8b5addbcf8c75f121bc4b2c81d71))
* **tx-history:** stamp block hash on processed summaries ([3a9bd3d](https://github.com/lambdasistemi/cardano-node-clients/commit/3a9bd3d8b25cc93dee355c2511c6bd573c7aad9c))
* **tx-history:** satisfy lint on lookup rows ([7960dc1](https://github.com/lambdasistemi/cardano-node-clients/commit/7960dc11ca120b1a4420f60bba3e464fd528ad32))
* **n2c:** bound stalled LSQ responses ([16fa3e3](https://github.com/lambdasistemi/cardano-node-clients/commit/16fa3e3d1da12feedbe00f0f1543a32e734714af))
* **n2c:** monitor LSQ liveness at connection scope ([e056141](https://github.com/lambdasistemi/cardano-node-clients/commit/e0561419051b7e8abf89288d2a9d55ed0f1af5eb))

## [0.1.3.0](https://github.com/lambdasistemi/cardano-node-clients/compare/v0.1.2.0...v0.1.3.0) (2026-05-15)

### Features

* tx-diff core supports resolved inputs ([199b55b](https://github.com/lambdasistemi/cardano-node-clients/commit/199b55b8a07c58cd52b75d118f2253b3461d0c61))
* tx-diff resolver chain ([8b0bd42](https://github.com/lambdasistemi/cardano-node-clients/commit/8b0bd420e38dd1eb9e8a2194942f24182a83cd2c))
* tx-diff N2C resolver ([5658993](https://github.com/lambdasistemi/cardano-node-clients/commit/565899326d40299496e0bd328fdef4090b94a79a))
* tx-diff Blockfrost web2 resolver ([b47914e](https://github.com/lambdasistemi/cardano-node-clients/commit/b47914ec288d8fa3191ff2509623f2b3050f36bf))
* tx-diff CLI wires N2C and web2 resolvers ([0c6b620](https://github.com/lambdasistemi/cardano-node-clients/commit/0c6b6201853af3a27fd91f93749f26a65026c419))

### Bug Fixes

* **release:** avoid duplicate AppImage assets ([c2d0247](https://github.com/lambdasistemi/cardano-node-clients/commit/c2d0247e14724f7482ebab2d4ee7f4bc8153684a))

## [0.1.2.0](https://github.com/lambdasistemi/cardano-node-clients/compare/v0.1.1.0...v0.1.2.0) (2026-05-14)

### Features

* **tx-diff:** add named collapse views ([d7c124d](https://github.com/lambdasistemi/cardano-node-clients/commit/d7c124dce97376d2ea7e0cf986d6581213d737aa))

## [0.1.1.0](https://github.com/lambdasistemi/cardano-node-clients/compare/v0.1.0.0...v0.1.1.0) (2026-05-14)

### Features

* **tx-diff:** add tree render modes ([4bb7b2f](https://github.com/lambdasistemi/cardano-node-clients/commit/4bb7b2faae8f5d7bc33c5a886a6d18ae2ed0a91d))

