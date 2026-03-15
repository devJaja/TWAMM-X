// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IZKVerifier} from "../interfaces/IZKVerifier.sol";
import {PoolId} from "@uniswap/v4-core/types/PoolId.sol";

/// @title ITWAMMXHook
/// @notice Public interface for TWAMM-X — privacy-preserving TWAMM hook for Uniswap v4.
interface ITWAMMXHook {

    // -----------------------------------------------------------------------
    // Structs
    // -----------------------------------------------------------------------

    /// @notice A ZK-hidden order commitment stored on-chain.
    /// @dev    The actual order parameters (amount, direction) are never stored;
    ///         only their Poseidon hash is kept until the ZK proof is verified at reveal.
    struct Commitment {
        bytes32 hash;       // Poseidon(owner, amountIn, zeroForOne, salt)
        uint64  expiry;     // earliest block.timestamp at which the order may execute
        bool    revealed;   // true once the ZK proof has been verified and order executed
    }

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event OrderCommitted(
        PoolId  indexed poolId,
        bytes32 indexed commitmentId,
        address indexed owner,
        uint64          expiry
    );

    event OrderRevealed(
        PoolId  indexed poolId,
        bytes32 indexed commitmentId,
        uint128         amountIn,
        bool            zeroForOne
    );

    event OrderCancelled(
        PoolId  indexed poolId,
        bytes32 indexed commitmentId,
        address indexed owner
    );

    event BatchExecuted(
        PoolId  indexed poolId,
        uint128         sell0Executed,
        uint128         sell1Executed,
        uint256         twapPrice
    );

    event LPRebateDistributed(
        PoolId  indexed poolId,
        uint256         amount0,
        uint256         amount1
    );

    /// @notice Emitted on each smoothed yield release to LPs.
    event YieldReleased(
        PoolId  indexed poolId,
        uint256         amount0,
        uint256         amount1,
        uint256         epochProgress
    );

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error OnlyPoolManager();
    error InvalidDelay();
    error InvalidProof();
    error CommitmentNotFound();
    error CommitmentAlreadyRevealed();
    error CommitmentNotExpired();
    error HashMismatch();
    error ZeroAmount();
    error NothingToDistribute();

    // -----------------------------------------------------------------------
    // Mutators
    // -----------------------------------------------------------------------

    /// @notice Commit a hidden order. Only the hash of the order is stored.
    /// @param poolId     Target pool.
    /// @param hash       Poseidon(owner, amountIn, zeroForOne, salt) — computed off-chain.
    /// @param delay      Seconds until the order becomes executable.
    /// @return commitmentId Unique ID for this commitment.
    function commitOrder(PoolId poolId, bytes32 hash, uint64 delay)
        external returns (bytes32 commitmentId);

    /// @notice Reveal and execute a matured commitment using a ZK proof.
    /// @param poolId        Target pool.
    /// @param commitmentId  ID returned by commitOrder.
    /// @param amountIn      Actual order amount (revealed).
    /// @param zeroForOne    Actual swap direction (revealed).
    /// @param salt          Salt used when computing the commitment hash.
    /// @param pA pB pC      Groth16 proof components.
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

    /// @notice Distribute accrued LP rebates back to the pool via donation.
    ///         Starts a new 24h smoothing epoch — yield is released linearly.
    function distributeLPRebate(PoolId poolId) external;

    /// @notice Release the currently vested portion of smoothed yield to LPs.
    function releaseYield(PoolId poolId) external;

    /// @notice Returns the currently releasable (vested but not yet donated) yield.
    function vestedYield(PoolId poolId) external view returns (uint256 amount0, uint256 amount1);

    // -----------------------------------------------------------------------
    // Views
    // -----------------------------------------------------------------------

    function getCommitment(PoolId poolId, bytes32 commitmentId)
        external view returns (Commitment memory);

    function pendingSells(PoolId poolId)
        external view returns (uint128 sell0, uint128 sell1);

    function lpRebateAccrued(PoolId poolId)
        external view returns (uint256 amount0, uint256 amount1);

    function verifier() external view returns (IZKVerifier);
}
