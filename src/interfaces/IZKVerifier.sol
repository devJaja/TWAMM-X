// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IZKVerifier
/// @notice Groth16 proof verifier interface — matches snarkjs solidityverifier output exactly.
interface IZKVerifier {
    /// @notice Verifies a Groth16 proof.
    /// @param _pA       G1 point (proof.pi_a)
    /// @param _pB       G2 point (proof.pi_b)
    /// @param _pC       G1 point (proof.pi_c)
    /// @param _pubSignals Public inputs: [commitmentHash, poolIdHash, expiry]
    /// @return True iff the proof is valid.
    function verifyProof(
        uint[2]    calldata _pA,
        uint[2][2] calldata _pB,
        uint[2]    calldata _pC,
        uint[3]    calldata _pubSignals
    ) external view returns (bool);
}
