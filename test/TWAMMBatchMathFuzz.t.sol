// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TWAMMBatchMath} from "../src/libraries/TWAMMBatchMath.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";

contract TWAMMBatchMathFuzz is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 constant NO_LIMIT_DOWN  = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant NO_LIMIT_UP    = TickMath.MAX_SQRT_PRICE - 1;

    // -----------------------------------------------------------------------
    // 1. Price direction invariant
    // -----------------------------------------------------------------------
    function testFuzz_sell0OnlyPriceFalls(
        uint128 liquidity, uint128 sell0, uint32 elapsed
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e12, type(uint64).max));
        sell0     = uint128(bound(sell0,     1,    1_000_000e18));
        elapsed   = uint32(bound(elapsed,    1,    7 days));

        (,, uint160 newSqrt) = TWAMMBatchMath.computeBatch(
            SQRT_PRICE_1_1, liquidity, sell0, 0, elapsed, NO_LIMIT_DOWN
        );
        assertLe(newSqrt, SQRT_PRICE_1_1, "sell0: price must not rise");
    }

    function testFuzz_sell1OnlyPriceRises(
        uint128 liquidity, uint128 sell1, uint32 elapsed
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e12, type(uint64).max));
        sell1     = uint128(bound(sell1,     1,    1_000_000e18));
        elapsed   = uint32(bound(elapsed,    1,    7 days));

        (,, uint160 newSqrt) = TWAMMBatchMath.computeBatch(
            SQRT_PRICE_1_1, liquidity, 0, sell1, elapsed, NO_LIMIT_UP
        );
        assertGe(newSqrt, SQRT_PRICE_1_1, "sell1: price must not fall");
    }

    // -----------------------------------------------------------------------
    // 2. Both outputs cannot be simultaneously non-zero
    // -----------------------------------------------------------------------
    function testFuzz_outputsDoNotExceedInputs(
        uint128 liquidity, uint128 sell0, uint128 sell1, uint32 elapsed
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e15, 1e30));
        sell0     = uint128(bound(sell0,     0,    1_000_000e18));
        sell1     = uint128(bound(sell1,     0,    1_000_000e18));
        elapsed   = uint32(bound(elapsed,    1,    7 days));

        (uint256 out0, uint256 out1,) = TWAMMBatchMath.computeBatch(
            SQRT_PRICE_1_1, liquidity, sell0, sell1, elapsed, NO_LIMIT_DOWN
        );

        assertTrue(out0 == 0 || out1 == 0, "only one output token per batch");
        if (sell0 == 0) assertEq(out1, 0, "no sell0 means no out1");
        if (sell1 == 0) assertEq(out0, 0, "no sell1 means no out0");
    }

    // -----------------------------------------------------------------------
    // 3. New sqrt price stays within Uniswap tick bounds
    // -----------------------------------------------------------------------
    function testFuzz_sqrtPriceWithinBounds(
        uint128 liquidity, uint128 sell0, uint128 sell1, uint32 elapsed
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e15, 1e30));
        sell0     = uint128(bound(sell0,     0,    1_000_000e18));
        sell1     = uint128(bound(sell1,     0,    1_000_000e18));
        elapsed   = uint32(bound(elapsed,    1,    7 days));

        (,, uint160 newSqrt) = TWAMMBatchMath.computeBatch(
            SQRT_PRICE_1_1, liquidity, sell0, sell1, elapsed, NO_LIMIT_DOWN
        );

        assertGe(newSqrt, TickMath.MIN_SQRT_PRICE, "sqrtPrice below MIN");
        assertLe(newSqrt, TickMath.MAX_SQRT_PRICE, "sqrtPrice above MAX");
    }

    // -----------------------------------------------------------------------
    // 4. Zero orders → no-op
    // -----------------------------------------------------------------------
    function testFuzz_noOrdersIsNoop(
        uint160 sqrtPrice, uint128 liquidity, uint32 elapsed
    ) public pure {
        sqrtPrice = uint160(bound(sqrtPrice, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        elapsed   = uint32(bound(elapsed,   1, 7 days));

        (uint256 out0, uint256 out1, uint160 newSqrt) =
            TWAMMBatchMath.computeBatch(sqrtPrice, liquidity, 0, 0, elapsed, NO_LIMIT_DOWN);

        assertEq(out0,    0,         "no orders: out0 must be 0");
        assertEq(out1,    0,         "no orders: out1 must be 0");
        assertEq(newSqrt, sqrtPrice, "no orders: price must be unchanged");
    }

    // -----------------------------------------------------------------------
    // 5. Elapsed = 0 → no-op
    // -----------------------------------------------------------------------
    function testFuzz_zeroElapsedIsNoop(
        uint160 sqrtPrice, uint128 liquidity, uint128 sell0, uint128 sell1
    ) public pure {
        sqrtPrice = uint160(bound(sqrtPrice, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE));
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));

        (uint256 out0, uint256 out1, uint160 newSqrt) =
            TWAMMBatchMath.computeBatch(sqrtPrice, liquidity, sell0, sell1, 0, NO_LIMIT_DOWN);

        assertEq(out0,    0,         "elapsed=0: out0 must be 0");
        assertEq(out1,    0,         "elapsed=0: out1 must be 0");
        assertEq(newSqrt, sqrtPrice, "elapsed=0: price must be unchanged");
    }

    // -----------------------------------------------------------------------
    // 6. Net direction determines price (one-sided)
    // -----------------------------------------------------------------------
    function testFuzz_netDirectionDeterminesPrice(
        uint128 liquidity, uint128 sellDominant, uint32 elapsed
    ) public pure {
        liquidity    = uint128(bound(liquidity,    1e15, 1e30));
        sellDominant = uint128(bound(sellDominant, 1,    1_000_000e18));
        elapsed      = uint32(bound(elapsed,       1,    7 days));

        (,, uint160 sqrtUp) = TWAMMBatchMath.computeBatch(
            SQRT_PRICE_1_1, liquidity, 0, sellDominant, elapsed, NO_LIMIT_UP
        );
        assertGe(sqrtUp, SQRT_PRICE_1_1, "sell1 only: price must rise or stay");

        (,, uint160 sqrtDown) = TWAMMBatchMath.computeBatch(
            SQRT_PRICE_1_1, liquidity, sellDominant, 0, elapsed, NO_LIMIT_DOWN
        );
        assertLe(sqrtDown, SQRT_PRICE_1_1, "sell0 only: price must fall or stay");
    }

    // -----------------------------------------------------------------------
    // 7. Two-sided batch never reverts
    // -----------------------------------------------------------------------
    function testFuzz_twoSidedNeverReverts(
        uint128 liquidity, uint128 sell0, uint128 sell1, uint32 elapsed
    ) public pure {
        liquidity = uint128(bound(liquidity, 1e15, 1e30));
        sell0     = uint128(bound(sell0,     1,    1_000_000e18));
        sell1     = uint128(bound(sell1,     1,    1_000_000e18));
        elapsed   = uint32(bound(elapsed,    1,    7 days));

        TWAMMBatchMath.computeBatch(SQRT_PRICE_1_1, liquidity, sell0, sell1, elapsed, NO_LIMIT_DOWN);
    }
}
