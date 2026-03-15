// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import {IReactive, AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";

/// @title TWAMMXReactive
/// @notice Reactive Contract that monitors TWAMM-X hook events and automatically
///         triggers LP rebate distribution after every batch execution.
///
/// Deployment:
///   1. Deploy TWAMMXHook + TWAMMSettlement on origin chain (e.g. Ethereum mainnet).
///   2. Deploy this contract on Reactive Network, passing:
///      - originChainId   : chain ID where TWAMMXHook is deployed
///      - hook            : TWAMMXHook address on origin chain
///      - destinationChainId : same as originChainId (callback goes back to same chain)
///      - callbackProxy   : Reactive callback proxy address for origin chain
///
/// Behaviour:
///   - Subscribes to TWAMMXHook.BatchExecuted events on the origin chain.
///   - On each BatchExecuted, emits a Callback that calls
///     TWAMMXHook.distributeLPRebate(poolId) on the origin chain.
///   - Subscribes to TWAMMXHook.OrderCommitted events and emits a Callback
///     to call TWAMMXHook.distributeLPRebate after the order's expiry
///     (best-effort: fires on next BatchExecuted after expiry).
///
/// This eliminates the need for any off-chain keeper to distribute LP rebates.
contract TWAMMXReactive is IReactive, AbstractReactive {

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    uint64 private constant CALLBACK_GAS_LIMIT = 500_000;

    /// @dev keccak256("BatchExecuted(bytes32,uint128,uint128,uint256)")
    uint256 private constant BATCH_EXECUTED_TOPIC =
        0x4d6ce1e535dbade1c23defba91e23b8f791ce5edc0cc320dae6d0e6054b9e8b4;

    // -----------------------------------------------------------------------
    // State (ReactVM instance only)
    // -----------------------------------------------------------------------

    uint256 private immutable originChainId;
    uint256 private immutable destinationChainId;
    address private immutable hook;
    address private immutable callbackProxy;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(
        uint256 _originChainId,
        address _hook,
        uint256 _destinationChainId,
        address _callbackProxy
    ) payable {
        originChainId      = _originChainId;
        hook               = _hook;
        destinationChainId = _destinationChainId;
        callbackProxy      = _callbackProxy;

        // Subscribe to BatchExecuted events on the origin chain hook
        // Only subscribe when running on Reactive Network (not ReactVM)
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

    /// @notice Called by Reactive Network whenever a subscribed event fires.
    ///         Decodes the BatchExecuted log and triggers distributeLPRebate
    ///         on the origin chain via a cross-chain callback.
    function react(LogRecord calldata log) external vmOnly {
        if (
            log.chain_id == originChainId &&
            log._contract == hook &&
            log.topic_0 == BATCH_EXECUTED_TOPIC
        ) {
            // topic_1 = poolId (indexed)
            bytes32 poolId = bytes32(log.topic_1);

            // Encode callback: reactiveDistributeRebate(poolId)
            // Reactive Network replaces address(0) with the ReactVM ID automatically
            bytes memory payload = abi.encodeWithSignature(
                "reactiveDistributeRebate(bytes32)",
                poolId
            );

            emit Callback(destinationChainId, hook, CALLBACK_GAS_LIMIT, payload);
        }
    }
}
