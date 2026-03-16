// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// ============================================================
// Hook errors
// ============================================================

/// @notice Caller is not the Uniswap v4 PoolManager.
error OnlyPoolManager();

/// @notice Order delay is outside [MIN_ORDER_DELAY, MAX_ORDER_DELAY].
error InvalidDelay();

/// @notice Groth16 proof verification failed.
error InvalidProof();

/// @notice Commitment hash does not match the stored value.
error HashMismatch();

/// @notice Commitment ID not found or caller is not the owner.
error CommitmentNotFound();

/// @notice Order has already been revealed and executed.
error CommitmentAlreadyRevealed();

/// @notice Order expiry has not been reached yet.
error CommitmentNotExpired();

/// @notice Amount or hash is zero.
error ZeroAmount();

/// @notice No rebate or yield available to distribute.
error NothingToDistribute();

// ============================================================
// Settlement errors
// ============================================================

/// @notice Caller is not the authorised hook contract.
error OnlyHook();

/// @notice Deposit amount is zero or commitment has no deposit.
error InsufficientDeposit();

/// @notice No claimable output balance for this caller.
error NothingToClaim();

/// @notice ERC-20 transfer returned false.
error TransferFailed();

/// @notice CoFHE async decryption result is not yet available.
error DecryptionNotReady();
