// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

import {SwapAndSprayRouter} from "../src/SwapAndSprayRouter.sol";
import {PayoutSpec} from "../src/libraries/PayoutSpec.sol";

interface IPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Mainnet dust proof: exact-input ETH to USDC on the hookless ETH/USDC 0.30% pool, SHARES to
/// three keyless addresses. Set ROUTER, SWAP_WEI and DEPLOYER_PRIVATE_KEY.
contract RouterProof is Script {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    IPriceFeed internal constant ETH_USD = IPriceFeed(0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70);
    uint256 internal constant SPRAY_FEE_BPS = 30;

    function recipient(uint256 index) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("swapandspray.phase3.recipient.", index)))));
    }

    function run() external {
        require(block.chainid == 8453, "Base mainnet only");

        SwapAndSprayRouter router = SwapAndSprayRouter(payable(vm.envAddress("ROUTER")));
        uint256 swapWei = vm.envUint("SWAP_WEI");
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");

        (, int256 price,,,) = ETH_USD.latestRoundData();
        require(price > 0, "Bad price");
        // Feed has 8 decimals, USDC 6, ETH 18. Accepts up to 3% below the feed, covering the 0.30% pool fee.
        uint256 minOutput = (swapWei * uint256(price) * 97) / 100 / 1e20;

        address[] memory recipients = new address[](3);
        uint256[] memory shares = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            recipients[i] = recipient(i + 1);
        }
        shares[0] = 5000;
        shares[1] = 3000;
        shares[2] = 2000;

        PayoutSpec memory spec = PayoutSpec({
            mode: 0,
            payer: vm.addr(key),
            minOutput: minOutput,
            maxFeeBps: SPRAY_FEE_BPS,
            recipients: recipients,
            values: shares
        });
        PoolKey memory pool = PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(USDC), 3000, 60, IHooks(address(0)));
        SwapParams memory params = SwapParams(true, -int256(swapWei), TickMath.MIN_SQRT_PRICE + 1);

        console2.log("minOutput", minOutput);
        console2.log("recipient1", recipients[0]);
        console2.log("recipient2", recipients[1]);
        console2.log("recipient3", recipients[2]);

        vm.startBroadcast(key);
        (uint256 amountIn, uint256 output) =
            router.swapAndSpray{value: swapWei}(pool, params, minOutput, spec, block.timestamp + 600);
        vm.stopBroadcast();

        console2.log("amountIn", amountIn);
        console2.log("output", output);
    }
}
