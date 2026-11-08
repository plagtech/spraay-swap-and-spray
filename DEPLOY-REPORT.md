# Deploy report: Base mainnet dust proof (Phase 3)

Date: 2026-11-08. Chain: Base (8453).

**Status: both contracts deployed and the router proof succeeded. Basescan verification is incomplete.** Sourcify has both contracts. Basescan accepted the submissions, but they stayed "Pending in queue" for more than 10 minutes and it publishes no source for either contract yet.

## Addresses

| Item | Address |
|---|---|
| SwapAndSprayRouter | `0x8cfb5eBa99170d284120B885A47b08E28FD27379` |
| SwapAndSprayHook | `0xD5a632a1F24231847f3C0Be6ADEcf209c1830044` |
| Deployer and payer | `0xe0DAa969c50ed9353bCDB9Fd6A3B3EA510F567E3` |
| SprayContract v2 | `0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c` |
| Uniswap v4 PoolManager | `0x498581fF718922c3f8e6A244956aF099B2652b2b` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

Hook CREATE2 salt: `0x8df`, through the deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C`. The address's low 14 bits are `0x44`, which is `afterSwap` and `afterSwapReturnDelta` only.

Both contracts return the PoolManager and SprayContract above from `poolManager()` and `spray()`.

## Transactions

| Step | Tx | Block | Gas used |
|---|---|---|---|
| Deploy router | [`0x7d569f58…d0b474`](https://basescan.org/tx/0x7d569f5891e20c97d69c3d7f113a9abe34bd895f399bf1a9da13277234d0b474) | 54,931,165 | 2,110,175 |
| Deploy hook | [`0x5014b1d6…f43cec`](https://basescan.org/tx/0x5014b1d68ed341651f6cfe3785475a05812dda0d25af4d87a7bc9d7ec1f43cec) | 54,931,287 | 1,902,046 |
| Router proof | [`0x2d8a7aca…13bd3ef`](https://basescan.org/tx/0x2d8a7acacf554cc353c14ad9cca8a86e8fbf4ef0416b2cb5ab6f6cc0313bd3ef) | 54,931,464 | 259,061 |

## Actual spend

Measured from the deployer's balance: 1,858,896,947,229,600 wei before, 1,673,826,016,961,080 wei after. USD uses the Chainlink ETH/USD reading taken at preflight, $2,128.0184.

| Item | Wei | USD |
|---|---|---|
| Router deploy, including L1 fee | 44,756,862,658,907 | $0.0952 |
| Hook deploy, including L1 fee | 41,068,812,922,593 | $0.0874 |
| Proof swap gas, including L1 fee | 5,245,254,687,020 | $0.0112 |
| ETH swapped | 94,000,000,000,000 | $0.2000 |
| **Total** | **185,070,930,268,520** | **$0.3938** |

The cap was $1.00. The swapped value was paid out to keyless addresses and to Spray's fee, so it is not recoverable.

## Router proof

Exact-input ETH to USDC, SHARES mode 5000 / 3000 / 2000, on the hookless ETH/USDC 0.30% pool (fee 3000, tick spacing 60). Empty `hookData`. Of the six fee tiers checked at preflight, this pool had the most active liquidity: 500,280,051,151,806,703, against 38,353,885,246,912,251 for the 0.05% pool.

Values below are raw USDC units (6 decimals), read from the transaction's USDC `Transfer` logs. Recipient balances before and after were read at blocks 54,931,463 and 54,931,464.

| Party | Address | Received |
|---|---|---|
| Recipient 1 | `0x478e50965525Ebf9E8e820F7222197a00395298a` | 99,621 |
| Recipient 2 | `0x2cF9A2b297FB4aFa5E48ca0645748927e11fBf12` | 59,772 |
| Recipient 3 | `0xab4348Ca57fdA0441e4CCFB723dbC9c0dC23F2CC` | 39,849 |
| Spray fee recipient | `0x033d3ce3BFd69B1d180869308822075219e771b5` | 597 |
| Payer leftover | deployer | 0 |
| **Pool output** | | **199,839** |

- Recipients were all at zero before the swap and each balance increased by exactly the amount shown.
- Recipients are `keccak256("swapandspray.phase3.recipient.", index)` truncated to 20 bytes. Nobody holds their keys.
- Delivered 199,242. Fee is `floor(199,242 * 30 / 10,000) = 597`, which is Spray's 30 bps with its rounding (29.96 bps effective on this size).
- Delivered + fee = 199,839, the entire output.
- After the transaction the router holds 0 USDC and 0 ETH, and its USDC allowance to Spray is 0.

## Verification

| Contract | Sourcify | Basescan |
|---|---|---|
| Router | `match` on creation and runtime | **Not verified**: "Pending in queue", no source published |
| Hook | `match` on runtime; creation match is null | **Not verified**: "Pending in queue", no source published |

Forge timed out waiting on Basescan after two submissions per contract. A further 10 minutes of polling `getsourcecode` still returned no source. No error about the source or compiler settings was returned. To retry:

```
ARGS=$(cast abi-encode 'constructor(address,address)' 0x498581fF718922c3f8e6A244956aF099B2652b2b 0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c)
forge verify-contract 0x8cfb5eBa99170d284120B885A47b08E28FD27379 src/SwapAndSprayRouter.sol:SwapAndSprayRouter --chain 8453 --constructor-args "$ARGS" --verifier etherscan --etherscan-api-key "$BASESCAN_API_KEY" --watch
forge verify-contract 0xD5a632a1F24231847f3C0Be6ADEcf209c1830044 src/SwapAndSprayHook.sol:SwapAndSprayHook --chain 8453 --constructor-args "$ARGS" --verifier etherscan --etherscan-api-key "$BASESCAN_API_KEY" --watch
```

## Deviations and findings

1. **Proof swap gas limit.** A rehearsal on a local Base fork reverted with Spray's "Insufficient gas" at forge's default limit (357,871), although the swap used about 259,000. Spray needs 150,000 gas remaining before each transfer, as `GAS.md` documents. The mainnet proof used `--gas-estimate-multiplier 300` (limit 825,756). No mainnet transaction failed.
2. **Hook not exercised on mainnet.** It is deployed but no pool attaches it, so only its deployment, wiring and address flags are proven here. The brief requires asking before seeding a hook pool.
3. **Sourcify hook creation match is null.** The runtime bytecode matches. The hook was created through the CREATE2 deployer.
4. **Added `script/RouterProof.s.sol`** for the proof. It was not in Phase 1. It sets the minimum output 3% below the Chainlink feed.
5. **Key handling.** The deploy scripts read `DEPLOYER_PRIVATE_KEY`, which was set per process from `SWAPSPRAY_DUST_KEY`.
6. **Rehearsal.** Both deploys and the proof ran on a local Anvil fork first. Those artifacts were kept out of `broadcast/`, so the `broadcast/*/8453` runs are the mainnet transactions.
7. **`README.md` is now out of date.** It still says "not deployed" and has no addresses for these contracts. It was left unchanged.

Nothing else deviated from Phase 0: the PoolManager, SprayContract address, `feeBps` of 30 and the unpaused state were all confirmed on-chain immediately before use.
