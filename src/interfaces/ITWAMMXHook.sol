// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";
import {IZKVerifier} from "./IZKVerifier.sol";
import "./Errors.sol";
import "./Events.sol";

/// @title ITWAMMXHook
/// @notice Public interface for TWAMM-X — privacy-preserving TWAMM hook for Uniswap v4.
interface ITWAMMXHook {

    // -----------------------------------------------------------------------
    // Structs
    // -----------------------------------------------------------------------

    /// @notice A ZK-hidden order commitment stored on-chain.
    struct Commitment {
        bytes32 hash;     // keccak256(owner, amountIn, zeroForOne, salt)
        uint64  expiry;   // earliest block.timestamp at which the order may execute
        bool    revealed; // true once the ZK proof has been verified and order executed
    }

    // -----------------------------------------------------------------------
    // Mutators
    // -----------------------------------------------------------------------

    /// @notice Commit a hidden order. Only the hash of the order is stored.
    /// @param poolId  Target pool.
    /// @param hash    keccak256(owner, amountIn, zeroForOne, salt) — computed off-chain.
    /// @param delay   Seconds until the order becomes executable.
    /// @return commitmentId Unique ID for this commitment.
    function commitOrder(PoolId poolId, bytes32 hash, uint64 delay)
        external returns (bytes32 commitmentId);

    /// @notice Reveal and execute a matured commitment using a ZK proof.
    function revealOrder(
        PoolId        poolId,
        bytes32       commitmentId,
        uint128       amountIn,
        bool          zeroForOne,
        bytes32       salt,
        uint[2]    calldata pA,
        uint[2][2] calldata pB,
        uint[2]    calldata pC
    ) external;

    /// @notice Cancel an unexpired commitment (owner only).
    function cancelOrder(PoolId poolId, bytes32 commitmentId) external;

    /// @notice Commit accrued rebates into a 24h linear smoothing epoch.
    function distributeLPRebate(PoolId poolId) external;

    /// @notice Release the currently vested portion of smoothed yield to LPs.
    function releaseYield(PoolId poolId) external;

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function getCommitment(PoolId poolId, bytes32 commitmentId)
        external view returns (Commitment memory);

    function pendingSells(PoolId poolId)
        external view returns (uint128 sell0, uint128 sell1);

    function lpRebateAccrued(PoolId poolId)
        external view returns (uint256 amount0, uint256 amount1);

    /// @notice Returns the currently releasable (vested but not yet donated) yield.
    function vestedYield(PoolId poolId)
        external view returns (uint256 amount0, uint256 amount1);

    function verifier() external view returns (IZKVerifier);
}
