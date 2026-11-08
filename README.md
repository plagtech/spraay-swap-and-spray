# SwapAndSpray

*A hook that makes a swap pay a list of people instead of one wallet.*

SwapAndSpray delivers a Uniswap v4 swap's output to up to 200 recipients atomically through Spraay's batch contract on Base. There is no intermediate balance in the payer's wallet and no second transaction.

## Deployments

Base mainnet (chain ID 8453):

| Contract | Address | Source |
|---|---|---|
| SwapAndSprayRouter | `0x8cfb5eBa99170d284120B885A47b08E28FD27379` | [Sourcify](https://repo.sourcify.dev/8453/0x8cfb5eBa99170d284120B885A47b08E28FD27379) |
| SwapAndSprayHook | `0xD5a632a1F24231847f3C0Be6ADEcf209c1830044` | [Sourcify](https://repo.sourcify.dev/8453/0xD5a632a1F24231847f3C0Be6ADEcf209c1830044) |
| SprayContract v2 | `0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c` | Existing Spraay contract |
| Uniswap v4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` | Existing Uniswap contract |

**The hook is deployed but has not yet been exercised on a live pool.** No pool attaches it so far. Its address flags and constructor wiring are confirmed on-chain, and it is tested on a Base fork.

### Router proof

[`0x2d8a7acacf554cc353c14ad9cca8a86e8fbf4ef0416b2cb5ab6f6cc0313bd3ef`](https://basescan.org/tx/0x2d8a7acacf554cc353c14ad9cca8a86e8fbf4ef0416b2cb5ab6f6cc0313bd3ef) swapped 0.000094 ETH (about $0.20) on the hookless ETH/USDC 0.30% pool and paid the output in SHARES mode, 50/30/20, to three keyless addresses. Amounts are raw USDC units (6 decimals).

| Party | Address | USDC received |
|---|---|---|
| Recipient 1 | `0x478e50965525Ebf9E8e820F7222197a00395298a` | 99,621 |
| Recipient 2 | `0x2cF9A2b297FB4aFa5E48ca0645748927e11fBf12` | 59,772 |
| Recipient 3 | `0xab4348Ca57fdA0441e4CCFB723dbC9c0dC23F2CC` | 39,849 |
| Spray fee recipient (30 bps of 199,242, rounded down) | `0x033d3ce3BFd69B1d180869308822075219e771b5` | 597 |
| **Pool output** | | **199,839** |

Full details are in [DEPLOY-REPORT.md](DEPLOY-REPORT.md).

## Two entry points

| | `SwapAndSprayRouter` | `SwapAndSprayHook` |
|---|---|---|
| Works on | Any v4 pool, with or without a hook | Pools that attach the hook |
| Exact-output | Yes (primary path) | **No** |
| Exact-input | Yes | Yes |
| Payout passed as | Calldata | `hookData` |
| Slippage | `amountLimit` and `spec.minOutput` | `spec.minOutput` only |

The hook is pool-bound. The router is pool-agnostic, so it can use the deepest pool available. The router always passes empty `hookData`, so on a pool that has the hook attached, the router settles and the hook stays out of it.

Both contracts have no owner, no admin functions, no storage and no fee of their own.

### Hook limits

- **Exact-input only.** A v4 `afterSwap` return delta applies to the unspecified currency, which on exact-output is the input. The hook reverts on exact-output when `hookData` is set.
- **Single-hop or final-hop only. This is not enforced, because a hook cannot see the route.** The hook takes the whole output, so a later hop has nothing to swap.
- **A router's own minimum-output check sees 0.** Set it to 0 and put your real minimum in `spec.minOutput`.

Empty `hookData` passes a swap through unchanged.

## How this differs from BatchDistributeHook

[BatchDistributeHook](https://github.com/plagtech/spraay-uniswap-v4-hook) is a standalone utility: an operator funds and calls a distribution function, with a pool used for attribution. SwapAndSprayHook is a callback hook: it uses `afterSwap` with a return delta, so the swap's own output funds the payout.

## Payout spec

```solidity
struct PayoutSpec {
    uint8 mode;           // 0 = SHARES, 1 = AMOUNTS
    address payer;        // receives any remainder and undelivered funds
    uint256 minOutput;    // minimum gross swap output, before the Spray fee
    uint256 maxFeeBps;    // reverts if Spray's live fee is above this
    address[] recipients; // 1 to 200
    uint256[] values;     // bps summing to 10000, or raw token amounts
}
```

**SHARES** splits the output by basis points. The router or hook sprays the largest amount the output can cover after Spray's fee, and flooring dust goes to the last recipient. Spray's rounded fee makes a few outputs impossible to spend exactly, so at most 1 wei can remain, and it goes to `payer`. A share that rounds to zero reverts the swap.

**AMOUNTS** pays fixed amounts. On exact-output, `amountSpecified` must equal `router.requiredOutput(spec)`, so nothing is left over. On exact-input, anything above the amounts and fee goes to `payer`. If the output cannot cover them, the swap reverts rather than paying less.

## Refunds

Spraay skips a recipient whose transfer fails and pushes the undelivered amount and its unused fee back to the caller in the same call. SwapAndSpray measures that by balance change and forwards it to `payer` in the same transaction. There is no ledger and nothing to claim.

**If the payer cannot receive the refund, the whole swap reverts.** This applies to a non-payable contract or a USDC-blocklisted address. If every recipient fails, the swap also reverts.

A successful swap does not mean every recipient was paid. Check `failedCount` in the `SwapSettled` event, or Spray's `RecipientFailed` events.

## Fees

Spraay charges **30 bps on top of the amount delivered**, read live from the contract. Uniswap pool fees apply as normal. SwapAndSpray adds no fee.

Spraay's owner can pause the contract or raise the fee to at most 5%. While it is paused, payouts revert. `maxFeeBps` protects you from a fee above what you agreed to.

Fee-on-transfer, rebasing and callback tokens are not supported by Spraay.

## Gas limits for callers

**Call the router with a gas limit from `eth_estimateGas` plus a buffer of at least 20%.** Spray requires about 150,000 gas to remain before every transfer, so a tight limit reverts late with "Insufficient gas", even when the limit is above the gas the call would use.

The mainnet proof used 259,061 gas under a 3× limit of 825,756. For that same call, a 275,000 limit reverts and `eth_estimateGas` returns 396,878. Measurements are in [GAS.md](GAS.md).

## Base addresses used

| Contract | Address |
|---|---|
| SprayContract v2 | `0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c` |
| Uniswap v4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

## Develop

```
git submodule update --init --recursive
forge test
forge test --fork-url https://mainnet.base.org --isolate
```

`forge test` skips the fork tests when not forking Base. No API key is needed.

Dependencies are pinned as submodules: v4-core `d153b048`, v4-periphery `7ebd04b1`.

## Licence

MIT. See [LICENSE](LICENSE).
