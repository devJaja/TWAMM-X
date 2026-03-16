// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";

// ============================================================
// Hook events
// ============================================================

/// @notice Emitted when a trader commits a hidden order.
/// @param poolId       Target pool.
/// @param commitmentId Unique ID for this commitment.
/// @param owner        Order owner.
/// @param expiry       Earliest execution timestamp.
event OrderCommitted(
    PoolId  indexed poolId,
    bytes32 indexed commitmentId,
    address indexed owner,
    uint64          expiry
);

/// @notice Emitted when a ZK proof is verified and the order enters the virtual queue.
/// @param poolId       Target pool.
/// @param commitmentId Commitment being revealed.
/// @param amountIn     Revealed order amount.
/// @param zeroForOne   Revealed swap direction.
event OrderRevealed(
    PoolId  indexed poolId,
    bytes32 indexed commitmentId,
    uint128         amountIn,
    bool            zeroForOne
);

/// @notice Emitted when an owner cancels an unexpired commitment.
/// @param poolId       Target pool.
/// @param commitmentId Cancelled commitment.
/// @param owner        Order owner.
event OrderCancelled(
    PoolId  indexed poolId,
    bytes32 indexed commitmentId,
    address indexed owner
);

/// @notice Emitted after each TWAMM virtual batch execution.
/// @param poolId         Target pool.
/// @param sell0Executed  Total token0 virtual sell volume in this batch.
/// @param sell1Executed  Total token1 virtual sell volume in this batch.
/// @param twapPrice      Ending sqrt price (Q64.96) after batch.
event BatchExecuted(
    PoolId  indexed poolId,
    uint128         sell0Executed,
    uint128         sell1Executed,
    uint256         twapPrice
);

/// @notice Emitted when a rebate epoch is committed for smoothed distribution.
/// @param poolId   Target pool.
/// @param amount0  Total token0 committed to this epoch (including rollover).
/// @param amount1  Total token1 committed to this epoch (including rollover).
event LPRebateDistributed(
    PoolId  indexed poolId,
    uint256         amount0,
    uint256         amount1
);

/// @notice Emitted on each incremental yield release to in-range LPs.
/// @param poolId        Target pool.
/// @param amount0       Token0 donated in this release.
/// @param amount1       Token1 donated in this release.
/// @param epochProgress Fraction of the 24h epoch elapsed, scaled to 1e18.
event YieldReleased(
    PoolId  indexed poolId,
    uint256         amount0,
    uint256         amount1,
    uint256         epochProgress
);

// ============================================================
// Settlement events
// ============================================================

/// @notice Emitted when a trader deposits plaintext funds into TWAMMSettlement.
/// @param commitmentId Commitment being funded.
/// @param owner        Depositor address.
/// @param token        Input token address.
/// @param amount       Deposited amount.
event Deposited(
    bytes32 indexed commitmentId,
    address indexed owner,
    address         token,
    uint128         amount
);

/// @notice Emitted when a trader deposits FHE-encrypted funds into TWAMMXSettlementFHE.
/// @param commitmentId Commitment being funded.
/// @param owner        Depositor address.
event EncryptedDeposit(
    bytes32 indexed commitmentId,
    address indexed owner
);

/// @notice Emitted after a settlement swap is executed through PoolManager.
/// @param commitmentId Commitment that was settled.
/// @param owner        Order owner receiving the output.
/// @param amountOut    Output token amount credited (plaintext settlement only).
event SwapExecuted(
    bytes32 indexed commitmentId,
    address indexed owner,
    uint256         amountOut
);

/// @notice Emitted when a trader withdraws their output tokens.
/// @param owner  Claimant address.
/// @param token  Output token address.
/// @param amount Amount withdrawn (plaintext settlement only).
event Claimed(
    address indexed owner,
    address         token,
    uint256         amount
);

/// @notice Emitted when a trader recovers funds after cancelling a commitment.
/// @param commitmentId Cancelled commitment.
/// @param owner        Refund recipient.
/// @param amount       Amount returned.
event Refunded(
    bytes32 indexed commitmentId,
    address indexed owner,
    uint256         amount
);
