// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/libraries/Hooks.sol";
import {TWAMMXHook} from "../src/TWAMMXHook.sol";
import {TWAMMSettlement} from "../src/TWAMMSettlement.sol";
import {Groth16Verifier} from "../src/libraries/Groth16Verifier.sol";

/// @notice Deploys Groth16Verifier + TWAMMSettlement + TWAMMXHook.
/// TWAMMXHook is deployed via CREATE2 to an address that encodes
/// BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG in its lower bits, as required by v4.
///
/// Usage:
///   export POOL_MANAGER=<v4_pool_manager_address>
///   forge script script/Deploy.s.sol --rpc-url <RPC> --private-key <PK> --broadcast
contract DeployScript is Script {

    uint160 constant REQUIRED_FLAGS = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

    function run() external {
        address poolManager = vm.envAddress("POOL_MANAGER");

        vm.startBroadcast();

        Groth16Verifier zkVerifier = new Groth16Verifier();

        // Deploy settlement with address(0) placeholder — wired after hook is known
        TWAMMSettlement settlement = new TWAMMSettlement(
            IPoolManager(poolManager),
            address(0)
        );

        // Mine CREATE2 salt off-chain (in script context, deployer = msg.sender)
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager),
            zkVerifier,
            settlement
        );
        bytes memory creationCode = abi.encodePacked(
            type(TWAMMXHook).creationCode,
            constructorArgs
        );

        // The CREATE2 factory used by forge broadcast is the deployer address itself
        // We mine the salt here in the script
        bytes32 salt;
        address predicted;
        for (uint256 i = 0; i < 200_000; i++) {
            salt      = bytes32(i);
            predicted = vm.computeCreate2Address(salt, keccak256(creationCode));
            if (uint160(predicted) & REQUIRED_FLAGS == REQUIRED_FLAGS) break;
        }
        require(uint160(predicted) & REQUIRED_FLAGS == REQUIRED_FLAGS, "no valid salt found");

        // Deploy using the mined salt
        TWAMMXHook hook = new TWAMMXHook{salt: salt}(
            IPoolManager(poolManager),
            zkVerifier,
            settlement
        );
        require(address(hook) == predicted, "address mismatch");

        settlement.setHook(address(hook));

        vm.stopBroadcast();

        console2.log("Groth16Verifier deployed at:", address(zkVerifier));
        console2.log("TWAMMSettlement deployed at:", address(settlement));
        console2.log("TWAMMXHook      deployed at:", address(hook));
        console2.log("Hook flags valid:           ", uint160(address(hook)) & REQUIRED_FLAGS == REQUIRED_FLAGS);
        console2.log("Hook wired into settlement via setHook().");
    }
}
