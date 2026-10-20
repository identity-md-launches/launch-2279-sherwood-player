# Test coverage

Run the suite without RPC access or additional dependencies:

```sh
forge build
FOUNDRY_FUZZ_SEED=0xee017cf0273c386d9f80b45175824c21d15b82057eee8d064f40c4fce39c42cd forge test
```

The earlier contributor's tests remain in place. The additions cover:

| Suite | Properties exercised |
| --- | --- |
| `SherwoodAdversarial.t.sol` | Constructor rejection, every pool-key field, all permission flags, signed extremes, threshold/dust boundaries, all four fee paths against actual PoolManager swap events and router balances, round trips, late game failures, malformed responses, large revert payloads, false-returning burn transfers, partial/zero-output buybacks, recursive swaps, two buybacks within one unlock, and buyback event contents. A router that syncs QUIVER before each swap still settles: full-jar swaps emit `BuybackDeferred` with the jar's amount and leave the target pool alone, and the next clear-slot trader plays the whole jar. Below the threshold nothing is deferred. |
| `SherwoodDeferred.t.sol` | Fresh PoolManager with both pools seeded using tokens only; backed fee claims, redemption by anyone, repeated redemption, deferred batch settlement, next-trader attribution, and buyback prepayment when the manager initially has no ETH. |
| `JarAccounting.invariant.t.sol` | 256 sequences of 96 calls mixing three funded traders, all swap directions/modes, routers with and without a pre-swap sync (pre-synced full-jar swaps must defer and keep the jar), early and late game failures, native/claim donations, redemptions, LP fee collection, and unauthorized execution attempts. |
| `QuiverStateful.t.sol` | 256 sequences of 64 calls across four holders: transfers, approvals, delegated spending, excessive spending, and revocation. Independent balance and allowance ledgers must match the token, whose supply stays fixed. |
| `Quiver.t.sol` additions | Zero/self transfers, zero recipients, unauthorized spending, allowance rollback on insufficient balance, and the full supply with infinite approval. |

New stateless fuzz properties use 1,000 cases each, configured inline. All handlers
use bounded inputs and explicit selectors. Expected failures are checked against
specific errors; unexpected handler reverts fail the invariant run. Deterministic
handler scenarios also demonstrate that transfers, claims, failures and successful
buybacks are reachable.

The jar's accounting identity is:

```text
liquid ETH + native ERC-6909 claims + ETH spent on successful buys
    = swap fees + native and claim donations
```

Separate invariants conserve ETH across every funded participant, conserve QUIVER
and IMD, and match successful plays to actual IMD delivered to the burn address.
Donated claims are created by paying the real PoolManager and minting backed
ERC-6909 claims. Invariant actions never overwrite contract storage or reset
balances with cheatcodes. `SettlementProbe` checks transient debts **inside**
the unlock callback, including while the router still owes its input; checking
transient storage after a top-level call would not establish this on Forge 1.8.

Fee expectations follow the implementation's documented rule: the fee is 1% of
the **gross ETH leg**, rounded down. That leg is the ETH a buyer pays in total,
fee included, or the ETH the pool pays out before the fee comes off a sell. The
tests derive the gross leg from the PoolManager's `Swap` event and the router's
own balance change, without reusing the hook's `/100` and `/99` formulas, and
check `fee * 100 <= gross < (fee + 1) * 100`. The LP fee is checked separately. Successful buys must spend the whole
liquid jar, credit the triggering transaction origin, and transfer positive IMD
output to the fixed burn address.

The PoolManager, AMM and QUIVER are real local contracts. Only the external IMD
token and Sherwood game are modeled at their required addresses. The game model
exercises the assumed empty-data BUY, transaction-origin attribution and up-front
pot fee, with explicit adversarial modes. Passing these tests does not establish
that the deployed Robinhood Chain game has those semantics, or verify rewards,
round settlement, holdings requirements, relayer identity, or live liquidity.
A fork rehearsal against the actual target pool and deployed game is still owed;
the default suite has no RPC, environment mutation, FFI or skipped fork tests.
