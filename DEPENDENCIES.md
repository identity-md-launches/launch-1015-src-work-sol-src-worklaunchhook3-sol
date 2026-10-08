# Vendored dependencies

These dependencies are ordinary source files, not submodules. Build and test
resolve them locally through the explicit remappings in `foundry.toml`.
Upstream source and license files are unmodified. Archives were downloaded over
HTTPS from the official repositories; `.git`, `.github`, environment files,
node_modules, release binaries and dependency installation scripts are not included.

| Local path | Upstream revision | Included source | License |
| --- | --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core v4.0.0](https://github.com/Uniswap/v4-core/tree/v4.0.0) | `src`, test utilities, upstream README and licenses | Per-file SPDX; BUSL-1.1 and MIT, see `licenses/` |
| `lib/openzeppelin-contracts` | [OpenZeppelin/openzeppelin-contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2) | `contracts`, README, LICENSE | MIT; vendored files retain their notices |
| `lib/forge-std` | [foundry-rs/forge-std v1.9.6](https://github.com/foundry-rs/forge-std/tree/v1.9.6) | `src`, README, licenses | MIT / Apache-2.0 |
| `lib/solmate` | [transmissions11/solmate 4b47a19038b798b4a33d9749d25e570443520647](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `src`, README, LICENSE | AGPL-3.0 / per-file SPDX |

Solmate is pinned to v4.0.0's upstream dependency revision. PoolManager uses its
`Owned` contract (AGPL-3.0-only). OpenZeppelin v5.0.2 is also the version pinned
by v4.0.0 (commit `dbb6104ce834628e473d2173bbc9d47f81a9eec3`). Tests use their own
router and the real PoolManager source; no PoolManager mock is substituted.

SHA-256 of downloaded source archives:

```text
1208271acb0cda5c1945e42d6d827797c628b04f7aeded0cc74e278197acbd03  v4-core-v4.0.0.tar.gz
18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a  openzeppelin-contracts-v5.0.2.tar.gz
53d2b498183cb7dc62cf726cc6c1a222ad728b0d87976a877ca1f3ed3707b1c6  forge-std-v1.9.6.tar.gz
9aa78449f8bc10931520500ec24734f089af9ac875a3334d8b512f8727241667  solmate-4b47a19038b798b4a33d9749d25e570443520647.tar.gz
```

The archives are provenance records, not runtime inputs. The compiler is supplied
by Foundry/the verifier and is not committed. No generated build artifacts or
external services are required by the tests.
