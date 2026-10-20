# Security design review

This is a local implementation review, not an independent audit or verification of deployed Sherwood code.

| Area | Review result / evidence |
| --- | --- |
| Callback authorization | All three enabled callbacks and the unlock callback require the immutable PoolManager. Direct-call tests cover each. Disabled callbacks are absent and their address bits are unset. |
| Pool scope | The complete launch pool ID is immutable, including token, native pair, fee, tick spacing and hook. Wrong-key initialization tests revert. There is no first-initializer token selection or mutable registration. |
| Permissions / NoOp | Address bits match `getHookPermissions()` and constructor checks them. Specified delta can only be `floor(abs(amountSpecified)/100)`, bounded before conversion to int128. No owner can increase it. It cannot absorb the whole input or replace the AMM's curve. Full specified-ETH fills are enforced. |
| Delta conservation | Fee collection debits the hook by exactly the positive delta returned to v4. Claims mint the same debit when manager cash is unavailable. Redemption burns claims for credit and takes the same ETH amount. Successful buyback prepayment cancels its native swap debit, and its IMD credit is taken to the fixed burn address. Failed self-calls revert every nested delta. Real-manager tests and stateful invariants assert zero unsettled deltas. |
| Failure isolation | External self-call catches all game/prepayment/burn reverts. Gas is capped and revert data discarded. Failure, missing pool, token transfer failure, and deliberate gas exhaustion are tested. A failed buyback does not erase the fee or reserve a player. |
| Reentrancy | Busy guard spans game execution and public claim redemption. Manager-authenticated swap callbacks reject nested execution during a buyback. Redemption cannot nest unlocks. A hostile game reentering redemption is tested. ETH receive performs no calls or stateful logic. |
| Tokens / transfer quirks | QUIVER is standard OpenZeppelin ERC-20, fixed supply with no tax/admin. The only other token is the specified IMD; manager.take uses v4 Currency's checked transfer. A failed burn transfer reverts the entire buyback. Nonstandard/rebasing IMD economics are not supported. |
| Player / routers | No player address from hook data is trusted. Sherwood owns attribution through tx.origin; smart-wallet/relayer limitations are explicit in README. No authorization in this project uses tx.origin. |
| Price / MEV | Target bound is the protocol extreme and no minimum output is imposed, per the brief. This knowingly allows severe slippage/MEV losses. Full input and positive output are checked. There is no oracle or valuable randomness in this project. |
| Funds / privilege | No owner, admin, proxy, emergency withdrawal, arbitrary target, approvals, sweep or mutable settings. Public redemption can only move claim-backed ETH into the same jar. Direct donations join the next buyback. Other accidentally sent assets may be trapped. |
| Initialization / LPs | Only exact launch key accepted. Factory must deploy and initialize atomically. No liquidity callbacks impede additions, withdrawals or zero-liquidity fee collection. |
| Gas / bounds | No loops in launch runtime. Fee and delta magnitudes are bounded by signed v4 types. Game execution is bounded independently from the outer trade; extremely low caller gas may still fail ordinary swap settlement. |
| Immutability | No external library linking, delegatecall, selfdestruct or upgrade mechanisms in launch contracts. External PoolManager/token/game behavior remains a deployment trust assumption. |

Validation performed: Solidity 0.8.26 compilation, deterministic Foundry tests with the specified fuzz seed, mixed-trade stateful invariants, formatting, and source-level accounting/access review. Gas-failure tests exercise the capped game call rather than merely throwing an ordinary revert.

Release checks still required: independent adversarial audit, Slither/Mythril if part of the release process (not run here), chain fork rehearsal, confirmation of the target game bytecode and its manager, deployment address mining against final bytecode/arguments, external game holding/prize rules, sufficient gas on production routers, source verification, and monitoring. There is no administrative remediation after deployment. No funded wallet or deployment was used here.
