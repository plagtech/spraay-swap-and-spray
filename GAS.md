# Gas report

**Result: `MAX_RECIPIENTS = 200`.** A 200-recipient batch fits under the ceiling on both entry points. 200 is also SprayContract's own hard limit, so no larger value is possible.

| Limit | Gas |
|---|---|
| Base per-transaction maximum | 16,777,216 |
| Ceiling for `MAX_RECIPIENTS` (70%) | 11,744,051 |

## Conditions

- Base mainnet fork at block 54,917,447, Foundry 1.8.4, solc 0.8.26, optimizer 1000 runs.
- Real SprayContract `0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c` and real USDC, in a real v4 swap.
- Every recipient is a never-funded address, the most expensive case for a USDC transfer.
- Figures are L2 execution gas including calldata gas. Base's L1 data fee is charged separately and is not included.

## Router: exact-output ETH to fixed USDC per recipient

Uses the live ETH/USDC 0.30% pool with no hook. Receipts are from real signed transactions on a local Anvil fork of that block. The forge column is the isolated call measurement.

| Recipients | Calldata bytes | Receipt gas used | Forge isolated gas | % of 16,777,216 (receipt) |
|---|---|---|---|---|
| 10 | 1,252 | 497,284 | 547,891 | 3.0% |
| 50 | 3,812 | 1,751,068 | 1,801,627 | 10.4% |
| 100 | 7,012 | 3,319,276 | 3,369,943 | 19.8% |
| 150 | 10,212 | 4,888,892 | 4,939,511 | 29.1% |
| 200 | 13,412 | 6,459,792 | 6,510,519 | 38.5% |

The forge figure ran 50,559 to 50,727 gas above the receipt at every size, so it is a slightly conservative stand-in where no receipt exists.

## Hook: exact-input ETH to USDC, SHARES

Uses a new hooked ETH/USDC pool on the fork, seeded at the live price, called through v4-core's `PoolSwapTest`. These are forge isolated figures only, and a production router will differ somewhat.

| Recipients | Calldata bytes | Forge isolated gas | % of 16,777,216 |
|---|---|---|---|
| 10 | 1,316 | 571,423 | 3.4% |
| 50 | 3,876 | 1,811,608 | 10.8% |
| 100 | 7,076 | 3,363,405 | 20.0% |
| 150 | 10,276 | 4,916,686 | 29.3% |
| 200 | 13,476 | 6,471,337 | 38.6% |

## Gas limit is not gas used

SprayContract reverts with "Insufficient gas" unless 150,000 gas remains before each transfer. A transaction whose gas limit equals its gas used therefore fails near the end of the batch. This was reproduced on the local fork.

For the router at 200 recipients, the minimum working gas limit found by bisection is **at most 6,890,389**, to within 500 gas. That is 41.1% of the Base maximum and below the ceiling. Callers should use `eth_estimateGas`, or add at least 300,000 gas to a known gas-used figure.

`test_Fork_MaxRecipients_FitUnderCeiling_Router` and `_Hook` execute `MAX_RECIPIENTS` recipients with the gas limit set to the ceiling.

## Scope of the 200 figure

It is measured for USDC. Other cases can cost more:

- **Native output.** Spray forwards up to 50,000 gas to each ETH recipient. If all 200 were contracts that burned it all, a batch would need roughly 12.3M gas (estimated, not measured). That is above the 70% ceiling but below the Base maximum. Recipients are chosen by the caller.
- **Other ERC-20s.** Spray does not cap gas on token transfers, so an expensive token costs more per recipient.

## Reproduce

```
forge test --fork-url https://mainnet.base.org --isolate -vv --match-path "test/fork/*"
```

Receipts, against a local fork only:

```
anvil --fork-url https://mainnet.base.org --chain-id 31337 --port 8547
RECIPIENTS=200 forge script script/LocalGasCheck.s.sol --rpc-url http://127.0.0.1:8547 --private-key "$ANVIL_TEST_KEY" --broadcast
```

Set `ANVIL_TEST_KEY` to one of the test keys Anvil prints at startup. `LocalGasCheck` refuses to run on any chain ID other than 31337.
