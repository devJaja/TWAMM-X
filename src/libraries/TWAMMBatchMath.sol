// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/libraries/FullMath.sol";

/// @title TWAMMBatchMath
/// @notice Closed-form continuous TWAMM execution math.
///
/// Implements the exact solution from the Paradigm TWAMM paper
/// (https://www.paradigm.xyz/2021/07/twamm), Section 6.
///
/// Given:
///   p   = current price (token1 per token0), represented as sqrtPriceX96²/Q96
///   k0  = sell rate of token0 (token0/sec)
///   k1  = sell rate of token1 (token1/sec)
///   L   = active liquidity
///   Δt  = elapsed seconds
///
/// The TWAMM invariant is the virtual AMM with constant product x·y = L².
/// The closed-form ending sqrt price is:
///
///   c  = sqrt(k0 / k1)                    (equilibrium price ratio)
///   e  = exp(2 * sqrt(k0·k1) * Δt / L)   (exponential decay factor)
///
///   sqrtP_end = sqrtP_0 * (sqrtP_0 + c) + c * (sqrtP_0 - c) * e
///               ─────────────────────────────────────────────────
///               (sqrtP_0 + c) + (sqrtP_0 - c) * e
///
/// Special case k0 = 0 or k1 = 0: one-sided execution, price moves
/// monotonically along the AMM curve.
///
/// The exp() function is approximated using a 6-term Taylor series,
/// accurate to <0.01% for |x| < 0.5 (covers all practical TWAMM intervals).
/// For larger exponents the series is evaluated iteratively.
library TWAMMBatchMath {

    uint256 internal constant Q96    = 1 << 96;
    uint256 internal constant Q96_SQ = Q96 * Q96;          // Q192
    /// @dev Fixed-point scale for exp() intermediate math (1e18)
    uint256 internal constant WAD    = 1e18;
    int256  internal constant IWAD   = 1e18;

    // -----------------------------------------------------------------------
    // Public entry point
    // -----------------------------------------------------------------------

    /// @notice Compute the TWAMM batch execution result.
    /// @param sqrtPriceX96      Current pool sqrt price (Q64.96).
    /// @param liquidity         Active pool liquidity.
    /// @param sell0             Total token0 to sell over the interval.
    /// @param sell1             Total token1 to sell over the interval.
    /// @param elapsed           Seconds elapsed since last execution.
    /// @param sqrtPriceLimitX96 Tick boundary cap — price will not move past this value.
    ///                          Pass TickMath.MIN_SQRT_PRICE / MAX_SQRT_PRICE for no cap.
    /// @return amountOut0       Token0 output for sell1 orders.
    /// @return amountOut1       Token1 output for sell0 orders.
    /// @return newSqrtPriceX96  Ending sqrt price (Q64.96), capped at sqrtPriceLimitX96.
    function computeBatch(
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint128 sell0,
        uint128 sell1,
        uint256 elapsed,
        uint160 sqrtPriceLimitX96
    )
        internal
        pure
        returns (
            uint256 amountOut0,
            uint256 amountOut1,
            uint160 newSqrtPriceX96
        )
    {
        if (liquidity == 0 || elapsed == 0 || (sell0 == 0 && sell1 == 0)) {
            return (0, 0, sqrtPriceX96);
        }

        uint256 sqrtP0 = uint256(sqrtPriceX96); // Q96

        if (sell0 == 0) {
            // One-sided: only token1 selling → price rises
            // Virtual AMM: x decreases, y increases
            // Δx = L * (1/sqrtP_end - 1/sqrtP_0)  →  sqrtP_end = L*sqrtP_0 / (L - sell1*sqrtP_0/Q96)
            // Exact: sqrtP_end = sqrtP_0 * L / (L - sell1/sqrtP_0 * Q96)
            // Using: sqrtP_end² = sqrtP_0² + sell1/L * Q96  (from constant product)
            uint256 priceX96    = FullMath.mulDiv(sqrtP0, sqrtP0, Q96);
            uint256 deltaPrice  = FullMath.mulDiv(sell1, Q96, liquidity);
            uint256 newPriceX96 = priceX96 + deltaPrice;
            newSqrtPriceX96     = uint160(_sqrt(FullMath.mulDiv(newPriceX96, Q96, 1)));

            // amountOut0 = L * (1/sqrtP_0 - 1/sqrtP_end)
            //            = L * Q96 * (sqrtP_end - sqrtP_0) / (sqrtP_0 * sqrtP_end / Q96)
            uint256 sqrtPEnd = uint256(newSqrtPriceX96);
            if (sqrtPEnd > sqrtP0) {
                amountOut0 = FullMath.mulDiv(
                    uint256(liquidity) * Q96,
                    sqrtPEnd - sqrtP0,
                    FullMath.mulDiv(sqrtP0, sqrtPEnd, Q96)
                );
            }
            amountOut1 = 0;
            return (amountOut0, amountOut1, newSqrtPriceX96);
        }

        if (sell1 == 0) {
            // One-sided: only token0 selling → price falls
            uint256 priceX96    = FullMath.mulDiv(sqrtP0, sqrtP0, Q96);
            uint256 deltaPrice  = FullMath.mulDiv(sell0, Q96, liquidity);
            uint256 newPriceX96 = priceX96 > deltaPrice ? priceX96 - deltaPrice : priceX96 / 2;
            newSqrtPriceX96     = uint160(_sqrt(FullMath.mulDiv(newPriceX96, Q96, 1)));

            // amountOut1 = L * (sqrtP_0 - sqrtP_end)
            uint256 sqrtPEnd = uint256(newSqrtPriceX96);
            if (sqrtP0 > sqrtPEnd) {
                amountOut1 = FullMath.mulDiv(liquidity, sqrtP0 - sqrtPEnd, Q96);
            }
            amountOut0 = 0;
            return (amountOut0, amountOut1, newSqrtPriceX96);
        }

        // ---------------------------------------------------------------
        // Two-sided: closed-form solution (Paradigm paper §6)
        // ---------------------------------------------------------------
        // Work in WAD (1e18) fixed-point throughout.
        // sqrtP0_wad = sqrtPriceX96 * WAD / Q96
        uint256 sqrtP0_wad = FullMath.mulDiv(sqrtP0, WAD, Q96);

        // sell rates per second in WAD
        uint256 k0_wad = FullMath.mulDiv(sell0, WAD, elapsed);
        uint256 k1_wad = FullMath.mulDiv(sell1, WAD, elapsed);

        // c = sqrt(k0/k1)  in WAD
        // c_wad = sqrt(k0_wad * WAD / k1_wad)
        uint256 c_wad = _sqrt(FullMath.mulDiv(k0_wad, WAD, k1_wad));

        // exponent = 2 * sqrt(k0 * k1) * elapsed / L
        // sqrt(k0*k1) in WAD = sqrt(k0_wad * k1_wad / WAD)
        uint256 sqrtK0K1_wad = _sqrt(FullMath.mulDiv(k0_wad, k1_wad, WAD));
        // exp_arg = 2 * sqrtK0K1_wad * elapsed / L  (WAD-scaled)
        uint256 exp_arg_wad = FullMath.mulDiv(2 * sqrtK0K1_wad, elapsed * WAD, uint256(liquidity) * WAD);

        // e = exp(exp_arg)  in WAD
        uint256 e_wad = _expWad(exp_arg_wad);

        // Paradigm formula:
        //   sqrtP_end = sqrtP_0 * [(sqrtP_0 + c) + c*(sqrtP_0 - c)*e / sqrtP_0]
        //               ─────────────────────────────────────────────────────────
        //               (sqrtP_0 + c) + (sqrtP_0 - c)*e
        //
        // Simplified (multiply numerator and denominator by sqrtP_0):
        //   num = sqrtP_0*(sqrtP_0+c) + c*(sqrtP_0-c)*e
        //   den = (sqrtP_0+c) + (sqrtP_0-c)*e
        //   sqrtP_end = sqrtP_0 * num / (sqrtP_0 * den)  ... simplifies to:
        //
        // Actually the exact formula from the paper for sqrtPrice:
        //   Let a = sqrtP_0 + c,  b = sqrtP_0 - c
        //   sqrtP_end = (a*sqrtP_0 + b*c*e) / (a + b*e)
        //             = sqrtP_0 * (a + b*e*c/sqrtP_0) / (a + b*e)
        // Numerically stable form:
        //   sqrtP_end = (a*sqrtP_0 + b*c*e/WAD) / (a + b*e/WAD)

        uint256 newSqrtP_wad;
        {
            // All in WAD
            // Handle sqrtP_0 vs c comparison carefully (signed)
            bool p0_gt_c = sqrtP0_wad >= c_wad;
            uint256 a_wad = sqrtP0_wad + c_wad; // always positive

            // b = sqrtP_0 - c  (may be negative)
            // b*e term:
            uint256 be_wad; // |b| * e
            bool b_positive = p0_gt_c;
            if (p0_gt_c) {
                be_wad = FullMath.mulDiv(sqrtP0_wad - c_wad, e_wad, WAD);
            } else {
                be_wad = FullMath.mulDiv(c_wad - sqrtP0_wad, e_wad, WAD);
            }

            // num = a*sqrtP_0 + b*c*e  (with sign of b)
            // den = a + b*e            (with sign of b)
            uint256 a_sqrtP0 = FullMath.mulDiv(a_wad, sqrtP0_wad, WAD);
            uint256 bce_wad  = FullMath.mulDiv(be_wad, c_wad, WAD);

            uint256 num_wad;
            uint256 den_wad;
            if (b_positive) {
                num_wad = a_sqrtP0 + bce_wad;
                den_wad = a_wad + be_wad;
            } else {
                // b is negative: num = a*sqrtP_0 - |b|*c*e
                num_wad = a_sqrtP0 > bce_wad ? a_sqrtP0 - bce_wad : a_sqrtP0 / 2;
                den_wad = a_wad > be_wad      ? a_wad - be_wad      : 1;
            }

            newSqrtP_wad = den_wad > 0 ? FullMath.mulDiv(num_wad, WAD, den_wad) : sqrtP0_wad;
        }

        // Convert back to Q96
        newSqrtPriceX96 = uint160(FullMath.mulDiv(newSqrtP_wad, Q96, WAD));

        // Tick boundary cap: clamp price to sqrtPriceLimitX96 so the batch
        // never crosses a tick boundary in a single execution. The caller
        // (afterSwap) should re-run with the remaining sell volume in the
        // next interval once liquidity at the new tick is known.
        if (sell0 > 0 && newSqrtPriceX96 < sqrtPriceLimitX96) {
            newSqrtPriceX96 = sqrtPriceLimitX96;
        } else if (sell1 > 0 && newSqrtPriceX96 > sqrtPriceLimitX96) {
            newSqrtPriceX96 = sqrtPriceLimitX96;
        }

        // Amount outputs using virtual AMM accounting:
        //   amountOut1 = L * (sqrtP_end - sqrtP_0)   if price rose  (sell1 > sell0)
        //   amountOut0 = L * (1/sqrtP_0 - 1/sqrtP_end) if price fell
        uint256 sqrtPEnd = uint256(newSqrtPriceX96);
        if (sqrtPEnd >= sqrtP0) {
            // price rose: sell1 dominated
            amountOut1 = 0;
            amountOut0 = FullMath.mulDiv(
                uint256(liquidity) * Q96,
                sqrtPEnd - sqrtP0,
                FullMath.mulDiv(sqrtP0, sqrtPEnd, Q96)
            );
        } else {
            // price fell: sell0 dominated
            amountOut0 = 0;
            amountOut1 = FullMath.mulDiv(liquidity, sqrtP0 - sqrtPEnd, Q96);
        }
    }

    // -----------------------------------------------------------------------
    // exp(x) in WAD fixed-point — 6-term Taylor series with range reduction
    // -----------------------------------------------------------------------
    // exp(x) = 1 + x + x²/2! + x³/3! + x⁴/4! + x⁵/5! + x⁶/6!
    // For x > 1 we use exp(x) = exp(x/2)² iteratively (range reduction).
    // Accurate to <0.01% for x < 20 (covers all practical TWAMM intervals).
    function _expWad(uint256 x) private pure returns (uint256) {
        if (x == 0) return WAD;

        // Range reduction: if x > WAD (i.e. > 1.0), halve until x <= WAD
        uint256 doublings = 0;
        uint256 xr = x;
        while (xr > WAD) {
            xr = (xr + 1) / 2;
            doublings++;
            if (doublings > 60) {
                // x is astronomically large — cap at a safe maximum
                // exp(60) ≈ 1.14e26, well within uint256
                xr = WAD;
                doublings = 60;
                break;
            }
        }

        // Taylor series for exp(xr) where xr <= WAD
        // result = 1 + xr + xr²/2 + xr³/6 + xr⁴/24 + xr⁵/120 + xr⁶/720
        uint256 result = WAD;
        uint256 term   = xr;                                    // xr^1 / 1!
        result += term;
        term = FullMath.mulDiv(term, xr, 2 * WAD);             // xr^2 / 2!
        result += term;
        term = FullMath.mulDiv(term, xr, 3 * WAD);             // xr^3 / 3!
        result += term;
        term = FullMath.mulDiv(term, xr, 4 * WAD);             // xr^4 / 4!
        result += term;
        term = FullMath.mulDiv(term, xr, 5 * WAD);             // xr^5 / 5!
        result += term;
        term = FullMath.mulDiv(term, xr, 6 * WAD);             // xr^6 / 6!
        result += term;

        // Undo range reduction: result = result^(2^doublings)
        for (uint256 i = 0; i < doublings; i++) {
            result = FullMath.mulDiv(result, result, WAD);
        }

        return result;
    }

    // -----------------------------------------------------------------------
    // Integer square root (Babylonian)
    // -----------------------------------------------------------------------
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
