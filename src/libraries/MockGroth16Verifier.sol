// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IZKVerifier} from "../interfaces/IZKVerifier.sol";

/// @title MockGroth16Verifier
/// @notice Test-only verifier — accepts any proof with non-zero commitmentHash.
///         Never deploy to production. Use Groth16Verifier (snarkjs output) instead.
contract MockGroth16Verifier is IZKVerifier {
    function verifyProof(
        uint[2]    calldata,
        uint[2][2] calldata,
        uint[2]    calldata,
        uint[3]    calldata _pubSignals
    ) external pure override returns (bool) {
        return _pubSignals[0] != 0;
    }
}
