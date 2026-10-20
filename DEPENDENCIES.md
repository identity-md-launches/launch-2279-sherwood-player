# Vendored dependencies

All files needed by builds and tests are ordinary files under `lib/`, without submodules or package installation. Only source directories and upstream licenses were retained; upstream project tooling is not part of the build.

| Directory | Upstream | Commit | License |
| --- | --- | --- | --- |
| `lib/v4-core` | https://github.com/Uniswap/v4-core | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | BUSL-1.1 and file-specific licenses; see upstream source headers and LICENSE |
| `lib/forge-std` | https://github.com/foundry-rs/forge-std | `b013eff2ac4fce26f34d789e6f5c49021c5ee817` | MIT / Apache-2.0; see LICENSE files |
| `lib/solmate` | https://github.com/transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` | AGPL-3.0 and file-specific licenses; imported `Owned.sol` is AGPL-3.0-only |
| `lib/openzeppelin-contracts` | https://github.com/OpenZeppelin/openzeppelin-contracts | `dbb6104ce834628e473d2173bbc9d47f81a9eec3` | MIT |

Solmate and OpenZeppelin versions match the v4-core dependency pins. No external linked libraries are required by the launch contracts. Project-written files carry SPDX MIT headers; upstream code retains its own notices and terms.
