// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title TWAMMXReactive
/// @notice Reactive Contract deployed on Reactive Network.
///         Watches TWAMMXHook.BatchExecuted events on the origin chain and
///         automatically calls hook.reactiveDistributeRebate(poolId) via callback —
///         no off-chain keeper required.
///
/// Deploy on Reactive Network:
///   forge create src/TWAMMXReactive.sol:TWAMMXReactive \
///     --rpc-url $REACTIVE_RPC_URL \
///     --private-key $REACTIVE_PRIVATE_KEY \
///     --value 0.01ether \
///     --constructor-args $ORIGIN_CHAIN_ID $HOOK_ADDR $ORIGIN_CHAIN_ID $CALLBACK_PROXY
contract TWAMMXReactive is IReactive, AbstractReactive {

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    uint64 private constant CALLBACK_GAS_LIMIT = 500_000;

    /// @dev keccak256("BatchExecuted(bytes32,uint128,uint128,uint256)")
    /// PoolId is bytes32 under the hood; non-indexed params are uint128,uint128,uint256
    uint256 private constant BATCH_EXECUTED_TOPIC =
        0x83b566dca93fe71a74ddaebf58cb9c5b1700ed3be921ac3e7892ef36e668a8fc;

    // -----------------------------------------------------------------------
    // State
    // -----------------------------------------------------------------------

    uint256 private immutable originChainId;
    uint256 private immutable destinationChainId;
    address private immutable hook;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    /// @param _originChainId      Chain ID where TWAMMXHook is deployed.
    /// @param _hook               TWAMMXHook address on the origin chain.
    /// @param _destinationChainId Chain ID to send callbacks to (same as origin).
    /// @param _callbackProxy      Reactive callback proxy for the destination chain
    ///                            (passed to AbstractReactive via service subscription).
    constructor(
        uint256 _originChainId,
        address _hook,
        uint256 _destinationChainId,
        address _callbackProxy  // used by Reactive Network infrastructure, not stored
    ) payable {
        // AbstractReactive constructor runs detectVm(), sets service + vendor
        // This is called implicitly via Solidity's constructor chaining.

        originChainId      = _originChainId;
        hook               = _hook;
        destinationChainId = _destinationChainId;

        // Suppress unused variable warning — callbackProxy is a deployment param
        // consumed by Reactive Network's infrastructure, not needed in contract logic.
        (_callbackProxy);

        // Subscribe to BatchExecuted events on the origin chain.
        // Guard with !vm: on Reactive Network (RN) we subscribe;
        // on ReactVM we skip (ReactVM can't call service.subscribe).
        if (!vm) {
            service.subscribe(
                _originChainId,
                _hook,
                BATCH_EXECUTED_TOPIC,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // -----------------------------------------------------------------------
    // IReactive — event processing (ReactVM only)
    // -----------------------------------------------------------------------

    /// @notice Called by Reactive Network on every subscribed event.
    ///         Fires a callback to hook.reactiveDistributeRebate(poolId)
    ///         on the origin chain.
    function react(LogRecord calldata log) external vmOnly {
        // Defensive checks — only process our specific event
        if (
            log.chain_id  != originChainId  ||
            log._contract != hook           ||
            log.topic_0   != BATCH_EXECUTED_TOPIC
        ) return;

        // topic_1 = poolId (first indexed param of BatchExecuted)
        bytes32 poolId = bytes32(log.topic_1);

        // Build callback payload.
        // Reactive Network automatically replaces the first 160 bits (address(0))
        // with the ReactVM ID before submitting the tx to the destination chain.
        bytes memory payload = abi.encodeWithSignature(
            "reactiveDistributeRebate(bytes32)",
            poolId
        );

        emit Callback(destinationChainId, hook, CALLBACK_GAS_LIMIT, payload);
    }
}
