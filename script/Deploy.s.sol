// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {TWAMMXHook} from "../src/TWAMMXHook.sol";
import {TWAMMSettlement} from "../src/TWAMMSettlement.sol";
import {Groth16Verifier} from "../src/libraries/Groth16Verifier.sol";

/// @notice Deploys Groth16Verifier + TWAMMSettlement + TWAMMXHook.
/// Usage:
///   export POOL_MANAGER=<v4_pool_manager_address>
///   forge script script/Deploy.s.sol --rpc-url <RPC> --private-key <PK> --broadcast
contract DeployScript is Script {
    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");

        vm.startBroadcast();

        Groth16Verifier zkVerifier  = new Groth16Verifier();

        // Settlement is deployed first; hook address is set after
        // (use a two-step init or deploy hook first with a placeholder)
        // Here we deploy hook first, then settlement pointing to it.
        // In production use CREATE2 to predetermine addresses.
        TWAMMSettlement settlement = new TWAMMSettlement(
            IPoolManager(poolManager),
            address(0) // placeholder — see note below
        );

        TWAMMXHook hook = new TWAMMXHook(
            IPoolManager(poolManager),
            zkVerifier,
            settlement
        );

        vm.stopBroadcast();

        console2.log("Groth16Verifier deployed at:", address(zkVerifier));
        console2.log("TWAMMSettlement deployed at:", address(settlement));
        console2.log("TWAMMXHook      deployed at:", address(hook));
        console2.log("NOTE: Re-deploy settlement with hook address, or use CREATE2 for atomic deployment.");
    }
}
