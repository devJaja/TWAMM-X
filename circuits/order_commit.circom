pragma circom 2.0.0;

include "node_modules/circomlib/circuits/poseidon.circom";
include "node_modules/circomlib/circuits/comparators.circom";

/// @title OrderCommit
/// @notice Proves knowledge of a valid TWAMM-X order that hashes to a
///         public commitment, without revealing order details on-chain.
///
/// Private inputs (known only to the prover / trader):
///   - owner      : address of the order owner (uint160 fits in field)
///   - amountIn   : token amount to sell (uint128)
///   - zeroForOne : swap direction (0 or 1)
///   - salt       : random 128-bit blinding factor
///
/// Public inputs (stored on-chain in the commitment):
///   - commitmentHash : Poseidon(owner, amountIn, zeroForOne, salt)
///   - poolIdHash     : keccak256(poolId) truncated to field element
///   - expiry         : block.timestamp + delay (uint64)
///
/// The circuit enforces:
///   1. commitmentHash == Poseidon(owner, amountIn, zeroForOne, salt)
///   2. amountIn > 0
///   3. zeroForOne ∈ {0, 1}
///   4. expiry > 0
template OrderCommit() {
    // -----------------------------------------------------------------------
    // Private inputs
    // -----------------------------------------------------------------------
    signal input owner;       // uint160 — fits in BN254 scalar field
    signal input amountIn;    // uint128
    signal input zeroForOne;  // 0 or 1
    signal input salt;        // uint128 blinding factor

    // -----------------------------------------------------------------------
    // Public inputs
    // -----------------------------------------------------------------------
    signal input commitmentHash; // Poseidon(owner, amountIn, zeroForOne, salt)
    signal input poolIdHash;     // uint256(poolId) mod p — informational, not constrained
    signal input expiry;         // uint64 — must be > 0

    // -----------------------------------------------------------------------
    // Constraint 1: commitmentHash == Poseidon(owner, amountIn, zeroForOne, salt)
    // -----------------------------------------------------------------------
    component hasher = Poseidon(4);
    hasher.inputs[0] <== owner;
    hasher.inputs[1] <== amountIn;
    hasher.inputs[2] <== zeroForOne;
    hasher.inputs[3] <== salt;

    commitmentHash === hasher.out;

    // -----------------------------------------------------------------------
    // Constraint 2: amountIn > 0
    // -----------------------------------------------------------------------
    signal amountInIsZero;
    component isZeroCheck = IsZero();
    isZeroCheck.in <== amountIn;
    amountInIsZero <== isZeroCheck.out;
    // amountInIsZero must be 0 (i.e. amountIn != 0)
    amountInIsZero === 0;

    // -----------------------------------------------------------------------
    // Constraint 3: zeroForOne ∈ {0, 1}  →  zeroForOne * (1 - zeroForOne) == 0
    // -----------------------------------------------------------------------
    signal zfoCheck;
    zfoCheck <== zeroForOne * (1 - zeroForOne);
    zfoCheck === 0;

    // -----------------------------------------------------------------------
    // Constraint 4: expiry > 0
    // -----------------------------------------------------------------------
    component expiryIsZero = IsZero();
    expiryIsZero.in <== expiry;
    expiryIsZero.out === 0;

    // -----------------------------------------------------------------------
    // poolIdHash is a public input but not constrained by the circuit —
    // it is verified by the Solidity hook (pubSignals[1] == uint256(poolId)).
    // We include it as a public signal so the verifier binds the proof to
    // a specific pool, preventing cross-pool proof replay.
    // -----------------------------------------------------------------------
    signal poolIdHashOut;
    poolIdHashOut <== poolIdHash;
}

component main {public [commitmentHash, poolIdHash, expiry]} = OrderCommit();
