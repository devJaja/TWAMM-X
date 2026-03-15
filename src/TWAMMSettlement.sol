// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/interfaces/external/IERC20Minimal.sol";

/// @title TWAMMSettlement
/// @notice Custodian and swap executor for TWAMM-X orders.
///
/// Flow:
///   1. Trader calls deposit() when committing an order — funds are held here.
///   2. Hook calls executeSwap() on reveal — actual swap runs through PoolManager,
///      output tokens are credited to the trader's claimable balance.
///   3. Trader calls claim() to withdraw output tokens.
///   4. Trader calls refund() to recover funds if they cancel before reveal.
contract TWAMMSettlement is IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error OnlyHook();
    error InsufficientDeposit();
    error NothingToClaim();
    error TransferFailed();

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event Deposited(bytes32 indexed commitmentId, address indexed owner, address token, uint128 amount);
    event SwapExecuted(bytes32 indexed commitmentId, address indexed owner, uint256 amountOut);
    event Claimed(address indexed owner, address token, uint256 amount);
    event Refunded(bytes32 indexed commitmentId, address indexed owner, uint256 amount);

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    address       public immutable hook;

    /// @dev Deposited input token per commitment
    mapping(bytes32 => address)  public depositToken;
    mapping(bytes32 => address)  public depositOwner;
    mapping(bytes32 => uint128)  public depositAmount;

    /// @dev Claimable output balances per (owner, token)
    mapping(address => mapping(address => uint256)) public claimable;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(IPoolManager _poolManager, address _hook) {
        poolManager = _poolManager;
        hook        = _hook;
    }

    // -----------------------------------------------------------------------
    // Trader-facing: deposit
    // -----------------------------------------------------------------------

    /// @notice Deposit input tokens when committing an order.
    ///         Must be called in the same tx as TWAMMXHook.commitOrder().
    /// @param commitmentId  ID returned by commitOrder.
    /// @param token         Input token address.
    /// @param amount        Amount to deposit (must match the committed amountIn).
    function deposit(bytes32 commitmentId, address token, uint128 amount) external {
        if (amount == 0) revert InsufficientDeposit();

        bool ok = IERC20Minimal(token).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        depositToken[commitmentId]  = token;
        depositOwner[commitmentId]  = msg.sender;
        depositAmount[commitmentId] = amount;

        emit Deposited(commitmentId, msg.sender, token, amount);
    }

    // -----------------------------------------------------------------------
    // Hook-facing: executeSwap
    // -----------------------------------------------------------------------

    /// @notice Called by the hook after ZK proof verification to execute the actual swap.
    ///         Pulls deposited funds, swaps through PoolManager, credits output to owner.
    /// @param commitmentId  The commitment being settled.
    /// @param key           PoolKey for the target pool.
    /// @param zeroForOne    Swap direction.
    function executeSwap(
        bytes32       commitmentId,
        PoolKey calldata key,
        bool          zeroForOne
    ) external {
        if (msg.sender != hook) revert OnlyHook();

        uint128 amountIn = depositAmount[commitmentId];
        if (amountIn == 0) revert InsufficientDeposit();

        address owner    = depositOwner[commitmentId];
        address tokenIn  = depositToken[commitmentId];

        // Clear deposit before external calls (CEI)
        delete depositAmount[commitmentId];
        delete depositToken[commitmentId];
        delete depositOwner[commitmentId];

        // Execute swap through PoolManager
        bytes memory result = poolManager.unlock(
            abi.encode(key, zeroForOne, amountIn, owner, tokenIn)
        );

        uint256 amountOut = abi.decode(result, (uint256));

        // Credit output to owner
        address tokenOut = zeroForOne
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        claimable[owner][tokenOut] += amountOut;

        emit SwapExecuted(commitmentId, owner, amountOut);
    }

    // -----------------------------------------------------------------------
    // IUnlockCallback
    // -----------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        (PoolKey memory key, bool zeroForOne, uint128 amountIn,,address tokenIn) =
            abi.decode(data, (PoolKey, bool, uint128, address, address));

        // Execute swap — exact input (negative amountSpecified)
        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(uint256(amountIn)),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // Settle input (negative delta = we owe the pool)
        // amount0 < 0 when zeroForOne (we pay token0)
        // amount1 < 0 when !zeroForOne (we pay token1)
        int128 inputDelta  = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();

        if (inputDelta < 0) {
            uint256 owed = uint256(int256(-inputDelta));
            poolManager.sync(zeroForOne ? key.currency0 : key.currency1);
            IERC20Minimal(tokenIn).transfer(address(poolManager), owed);
            poolManager.settle();
        }

        // Take output (positive delta = pool owes us)
        uint256 amountOut = 0;
        if (outputDelta > 0) {
            amountOut = uint256(int256(outputDelta));
            Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
            poolManager.take(outputCurrency, address(this), amountOut);
        }

        return abi.encode(amountOut);
    }

    // -----------------------------------------------------------------------
    // Trader-facing: claim
    // -----------------------------------------------------------------------

    /// @notice Withdraw output tokens after a swap has been executed.
    function claim(address token) external {
        uint256 amount = claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender][token] = 0;

        bool ok = IERC20Minimal(token).transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit Claimed(msg.sender, token, amount);
    }

    // -----------------------------------------------------------------------
    // Trader-facing: refund (after cancel)
    // -----------------------------------------------------------------------

    /// @notice Recover deposited funds after cancelling a commitment.
    ///         Can only be called by the original depositor.
    function refund(bytes32 commitmentId) external {
        if (depositOwner[commitmentId] != msg.sender) revert InsufficientDeposit();

        uint128 amount = depositAmount[commitmentId];
        address token  = depositToken[commitmentId];

        delete depositAmount[commitmentId];
        delete depositToken[commitmentId];
        delete depositOwner[commitmentId];

        bool ok = IERC20Minimal(token).transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit Refunded(commitmentId, msg.sender, amount);
    }
}
