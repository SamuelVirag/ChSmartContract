// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ChFactory} from "../src/ChFactory.sol";
import {ChRouter} from "../src/ChRouter.sol";

/// @title Deploy ChSwap
/// @notice Deploys Factory and Router. Requires WETH address for the target chain.
/// @dev Usage:
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
///   Environment variables:
///     WETH_ADDRESS — WETH contract address on the target chain
///     ADMIN_ADDRESS — (optional) feeToSetter, defaults to deployer
contract DeployChSwap is Script {
    function run() external {
        address weth = vm.envAddress("WETH_ADDRESS");
        address admin = vm.envOr("ADMIN_ADDRESS", msg.sender);

        console.log("Deploying ChSwap DEX");
        console.log("  WETH:", weth);
        console.log("  Admin:", admin);

        vm.startBroadcast();

        ChFactory factory = new ChFactory(admin);
        console.log("  Factory deployed:", address(factory));

        ChRouter router = new ChRouter(address(factory), weth);
        console.log("  Router deployed:", address(router));

        vm.stopBroadcast();

        console.log("");
        console.log("Deployment complete.");
        console.log("  Factory:", address(factory));
        console.log("  Router:", address(router));
        console.log("  WETH:", weth);
        console.log("  Admin:", admin);
    }
}
