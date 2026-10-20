# Sherwood Player (QUIVER)

A fixed-supply ERC-20 and an immutable Uniswap v4 fee hook for Robinhood Chain (chain ID 4663). The QUIVER/native ETH pool contributes 1% of its ETH side to a jar. The swap whose fee takes the available jar to **at least 0.005 ETH** attempts an ETH → IMD buy through the requested Sherwood v2 pool and sends the output directly to the burn address. A previously funded jar is also attempted on the next swap. There is no owner, administration, upgrade, withdrawal, configurable recipient, or configurable pool.

## Build and test

Dependencies are vendored as ordinary source files. No network, environment variables, FFI, filesystem cheatcode permissions, or submodules are needed for the tests.

```sh
forge build
FOUNDRY_FUZZ_SEED=0xee017cf0273c386d9f80b45175824c21d15b82057eee8d064f40c4fce39c42cd forge test
forge fmt --check
```

Solidity is pinned to **0.8.26**, EVM Cancun, optimizer 200 runs, with `bytecode_hash = "none"`. The deployment chain must support Cancun, including the transient storage used by v4-core.

## Contracts and deployment parameters

| Contract | Constructor | Deployment responsibility |
| --- | --- | --- |
| `Quiver` | No arguments | Factory deploys first; all 1,000,000,000 tokens, 18 decimals (`10^27` units), mint once to that factory. Name `Sherwood Player`, symbol `QUIVER`. |
| `SherwoodPlayerHook` | `(IPoolManager manager_, address token_)` | Pass the launch chain's actual PoolManager (`$poolManager`) and newly deployed QUIVER (`$token`). Neither address is hardcoded or checked by calling outside code during construction. |

The two launch contracts have no privileged roles. Token distribution and the factory's LP position remain the launch factory's responsibility. There is no manifest in this project; the separate launch process supplies it.

The QUIVER pool key is fixed to `(native ETH, QUIVER, 12500, 60, this hook)`. Native ETH sorts first. The opening price and liquidity are the launch policy/factory's responsibility; the hook accepts any valid opening price. Initialize and seed atomically with deployment to avoid post-deployment initialization front-running. The hook does not restrict the initializer's sender; it authenticates the PoolManager and the complete pool key.

**Mine the CREATE2 salt against the final optimized creation code plus both ABI-encoded constructor arguments, using the actual deploying factory address.** The address must satisfy `uint160(hook) & 0x3fff == 0x20cc` (8396). The constructor enforces the address bits. `test/helpers/HookFixture.sol` demonstrates the computation and actual CREATE2 deployment. Changing compiler settings, arguments, or factory changes the required salt. Never deploy the test driver or mocks as launch contracts.

The enabled callbacks are `beforeInitialize`, `beforeSwap`, and `afterSwap`, plus both swap return-delta permissions. Initialization validates the pool and prevents initialization against a predicted hook address without code. Swap deltas charge ETH in both directions and swap modes. No liquidity callbacks are enabled: zero-liquidity fee collection and removal remain available to the factory.

The design is a minimal general hook, implementing the enabled ABI directly rather than importing a large base contract. Configuration: no shares, no access controller, no pausing, explicit v4 settlement, checked signed casts, ordinary storage reentrancy guard, no LP-fee override. The 1.25% pool LP fee is separate from this hook's charge.

## Fee accounting

Fees round down to whole wei. Fees below one wei are zero. ETH is always the charged currency; the hook never taxes or retains QUIVER.

| Trade | Fee and callback |
| --- | --- |
| Exact-input ETH → QUIVER | Reserve `inputBudget / 100` in `beforeSwap`; the remainder goes to the AMM. The user's total ETH debit remains their specified budget. |
| Exact-output QUIVER → ETH | Reserve `requestedETH / 99` in `beforeSwap`; ask the AMM for requested ETH plus that fee. The user receives their specified ETH output. |
| Exact-output ETH → QUIVER | Charge `actualAMMETHInput / 99` in `afterSwap`, on top of the AMM input. |
| Exact-input QUIVER → ETH | Charge `actualAMMETHOutput / 100` in `afterSwap`, deducted from ETH output. |

The fee is 1% of the **gross ETH leg** in all four modes: the ETH the buyer pays in total, or the ETH the pool pays out before the fee is deducted. On exact input that leg is the amount itself, so the fee is `amount / 100`. On exact output the ETH amount excludes the fee, so it is grossed up: `amount / 99` equals `(amount + fee) / 100` exactly under floor division. The same net result therefore costs the same fee whichever swap mode a router picks. **Specified-ETH trades must fill fully.** A price bound or insufficient liquidity causing a partial exact-input buy or exact-output sell reverts the trade atomically, avoiding a fee on unexecuted ETH. Unspecified-ETH trades can fill partially and pay only on actual ETH. Routers must account for these rules and the extra ETH on exact-output buys in their limits.

`PoolManager.take` pays a fee directly into the jar when the manager has enough ETH. If input settlement has not happened yet and the manager lacks ETH (notably a token-only launch pool), the hook mints itself an ETH ERC-6909 claim instead. This prevents `NativeTransferFailed` from blocking a valid trade. These claims are not liquid jar ETH and cannot finance a buyback until redeemed. Any later swap automatically redeems as much as the manager can pay. Anyone may also call `redeemFees()` in a separate transaction, which unlocks the manager, burns backed claims, and takes ETH into the hook. Redemption cannot choose a player or trigger a buyback. The hook's payable receiver accepts manager payments and donations; donations join the jar and the next eligible swap spends them too.

## Sherwood buyback and identity

The immutable target is exactly:

| Parameter | Value |
| --- | --- |
| Currency 0 | Native ETH (`address(0)`, not WETH) |
| Currency 1 | IMD `0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127` |
| LP fee | `9000` |
| Tick spacing | `180` |
| Game hook | `0xc33c907127b94303F578d6Be551C36F45939e0cC` |
| Output destination | `0x000000000000000000000000000000000000dEaD` |
| Swap mode | Exact input, ETH → IMD, all liquid ETH in the jar |
| Price bound | `TickMath.MIN_SQRT_PRICE + 1`, v4-core's unrestricted downward bound |
| Hook data | Empty, Sherwood v2's default BUY move |

There is no minimum-output slippage protection beyond requiring positive output and full ETH consumption, as requested. The buyback is exposed to price manipulation, sandwiching, and adverse execution. An exact-input swap's amount includes Sherwood's own pot fee and the AMM's LP fee. The hook prepays the manager before invoking the game, making that game's immediate pot-fee withdrawal possible even without spare manager ETH. All output is taken directly to the burn address; this is a transfer to an irrecoverable address, not an ERC-20 `totalSupply` reduction.

[Sherwood's published v2 source](https://github.com/MirakoolDev/sherwood/blob/754206eee64c5e68490e7978a6058ded4faecb9b/src/SherwoodV2.sol) uses `tx.origin` to credit players and treats empty hook data as BUY. This hook preserves that transaction context and cannot override player identity through untrusted router data. For ordinary wallet transactions, the tipping wallet is credited; with account abstraction, relayers, or smart wallets, **Sherwood credits the originating transaction signer, which may be a bundler or relayer**. This is external game behavior, not an authorization mechanism in this hook. No router allowlist is necessary because this hook grants no rights based on player identity.

**A board entry is not a guaranteed prize.** That published game tracks tokens bought for the player and reduces prizes when the player's IMD balance is below those buys at settlement; it also checks holdings at claim time. Since this project burns the bought IMD, a player with no separate IMD holdings may forfeit all prizes. Holding independently acquired IMD may satisfy the game's checks. This hook does not implement, settle, or claim Sherwood prizes. The requested automatic BUY and burn are implemented unchanged.

## Failure isolation and operation

The buyback, prepayment, game effects, and burn execute in an external **self-call** while the manager is already unlocked. It never calls `unlock` inside an existing unlock. If any step reverts, every effect in that self-call rolls back, the fee remains in the jar, and the outer swap continues. The next swap retries with its own originating player; failed attempts do not reserve the previous player's identity. A busy guard rejects recursive callbacks and redemption during a buyback. Only the manager can call enabled callbacks or `unlockCallback`; only the hook itself can call `executeBuyback`.

**Routers that sync before swapping.** The prepayment settles native ETH, which requires the manager's single transient synced-currency slot to be clear, and `sync(address(0))` would clear it. A router that calls `sync(QUIVER)` and transfers its input *before* `swap` and only calls `settle()` afterwards would then settle nothing and its whole unlock would revert `CurrencyNotSettled`. So when the slot holds a currency at `afterSwap`, the hook does not attempt the buyback: it emits `BuybackDeferred(player, ethHeld)`, keeps the jar, and the swap succeeds. The buyback runs on the next swap that arrives with the slot clear. Uniswap's own v4 routers swap first and sync-transfer-settle afterwards, so they trigger buybacks normally; a venue whose router always pre-syncs cannot tip the jar, and some other route of the pool must. Zero-slot and occupied-slot sells are both tested.

Each buyback forwards at most **2,000,000 gas**, retaining **150,000 gas** in the callback. Revert data is discarded to prevent a memory-expansion attack. With very little remaining gas an attempt is skipped; otherwise it may fail for insufficient forwarded gas and retry later. A caller must always provide enough gas for the ordinary trade and its router's settlement. Integrators should budget roughly 2.5 million extra gas for swaps with a full jar and monitor actual game execution. Gas estimators can choose a cheaper failed-buyback path because failure is tolerated, so specify a sufficient gas limit when a successful play matters. A game whose execution permanently exceeds the fixed budget cannot be played by this immutable hook.

There is no keeper dependency for normal swaps. A voluntary keeper can redeem deferred claims once manager liquidity is available. Monitor `FeeCollected`, `FeesRedeemed`, `BuybackSucceeded`, `BuybackFailed`, `BuybackDeferred`, the hook's ETH balance and its manager claim balance. Low gas skips do not emit a failure event; a pre-synced router emits `BuybackDeferred` instead of `BuybackFailed`. Persistent failures require investigating target initialization, liquidity, token transfers, game rules, and gas; there is no admin recovery, target replacement, rescue of accidentally sent ERC-20s, or fee withdrawal.

Before launch, the deployer must verify the supplied PoolManager, target pool initialization/liquidity, token identity, game runtime/source correspondence, chain ID, Cancun support, and current attribution/prize rules, then rehearse against a recent Robinhood Chain fork. The target addresses are requester-supplied constants. Live chain code was **not verified** in this task: the explorer API returned HTTP 403, and the deterministic suite uses a local real PoolManager with game mocks. Published source inspection is not proof of deployed code. Independent security review and deployment/fork rehearsal remain release responsibilities. No transactions were broadcast.

## Validation scope

The deterministic suite covers actual CREATE2 permission mining, initialization/key authentication, all enabled callbacks, four fee paths, dust and partial fills, threshold boundary/crossing, full-jar spending, burn destination, transaction-origin attribution, failure/retry with another player, a router that pre-syncs its input across the swap (buyback deferred, swap succeeds, next clear-slot swap plays), missing target pool, burn-transfer failure rollback, game OOG, reentrancy, factory fee collection, fresh token-only pools, partial claim redemption, and token supply/transfers/allowances. Fuzz tests check fee math and conservation. Stateful invariants run mixed exact-input/output buys and sells with game successes/failures and check ETH/token conservation and zero outstanding manager deltas. There are 64 stateful sequences of 64 calls, checking all three invariants, and 256 cases per fuzz test by default.

See [SECURITY.md](SECURITY.md) for the design review and remaining release checks, and [DEPENDENCIES.md](DEPENDENCIES.md) for pinned vendored versions.
