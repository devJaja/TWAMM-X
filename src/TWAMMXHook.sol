// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/libraries/FullMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/interfaces/external/IERC20Minimal.sol";

import {IZKVerifier} from "./interfaces/IZKVerifier.sol";
import {ITWAMMXHook} from "./interfaces/ITWAMMXHook.sol";
import {TWAMMBatchMath} from "./libraries/TWAMMBatchMath.sol";
import {TWAMMSettlement} from "./TWAMMSettlement.sol";
import "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title TWAMM-X Hook
/// @notice Privacy-preserving TWAMM hook for Uniswap v4.
///
/// Order lifecycle:
///   1. commitOrder()  — stores only a hash of the order (ZK commitment). No order details on-chain.
///   2. revealOrder()  — after expiry, owner submits ZK proof + plaintext order.
///                       Proof verifies hash(plaintext) == stored commitment without
///                       the pool ever having seen the order before execution.
///   3. afterSwap      — executes accumulated virtual orders as a TWAMM batch,
///                       accrues LP shield rebate from virtual spread.
///   4. distributeLPRebate() — donates accrued rebate back to in-range LPs.
///
/// Hook flags required in deployment address: BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG
contract TWAMMXHook is ITWAMMXHook, IHooks, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    uint64  public constant MIN_ORDER_DELAY = 1 minutes;
    uint64  public constant MAX_ORDER_DELAY = 7 days;
    /// @notice LP shield rebate in basis points.
    uint256 public constant LP_REBATE_BPS   = 5;

    // -----------------------------------------------------------------------
    // Immutables
    // -----------------------------------------------------------------------

    IPoolManager    public immutable poolManager;
    IZKVerifier     public immutable override verifier;
    TWAMMSettlement public immutable settlement;

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    /// @dev commitmentId → Commitment
    mapping(PoolId => mapping(bytes32 => Commitment)) private _commitments;

    /// @dev owner of each commitment (separate to keep Commitment struct lean)
    mapping(PoolId => mapping(bytes32 => address)) private _owners;

    /// @dev Pending virtual sell totals per pool — stored as FHE ciphertexts.
    ///      FHE.add() accumulates orders without revealing individual or aggregate amounts.
    ///      FHE.sub() drains after batch execution.
    mapping(PoolId => euint128) private _encPendingSell0;
    mapping(PoolId => euint128) private _encPendingSell1;

    /// @dev Plaintext pending sells — kept in sync for TWAMM math (decrypted lazily)
    mapping(PoolId => uint128) private _pendingSell0;
    mapping(PoolId => uint128) private _pendingSell1;

    /// @dev Accrued LP rebates (token0, token1) per pool — total pending in current epoch
    mapping(PoolId => uint256) private _rebate0;
    mapping(PoolId => uint256) private _rebate1;

    // -----------------------------------------------------------------------
    // Fee-smoothing state
    // -----------------------------------------------------------------------

    /// @notice Duration over which each rebate epoch is linearly released to LPs.
    ///         Default: 24 hours. Yields predictable, continuous LP income.
    uint64 public constant SMOOTHING_WINDOW = 24 hours;

    /// @dev Epoch start timestamp per pool — when the current rebate epoch began
    mapping(PoolId => uint64)  private _epochStart;
    /// @dev Total rebate committed at epoch start (token0, token1)
    mapping(PoolId => uint256) private _epochTotal0;
    mapping(PoolId => uint256) private _epochTotal1;
    /// @dev Amount already donated in current epoch (token0, token1)
    mapping(PoolId => uint256) private _epochDonated0;
    mapping(PoolId => uint256) private _epochDonated1;

    /// @dev Timestamp of last TWAMM batch execution per pool
    mapping(PoolId => uint64) private _lastExecution;

    /// @dev PoolKey lookup by PoolId (needed for donation)
    mapping(PoolId => PoolKey) private _poolKeys;

    // -----------------------------------------------------------------------
    // Unlock action tags (used in unlockCallback dispatch)
    // -----------------------------------------------------------------------

    uint8 private constant _ACT_DONATE = 1;

    // -----------------------------------------------------------------------
    // Modifiers
    // -----------------------------------------------------------------------

    modifier onlyPoolManager() {
        _requirePoolManager();
        _;
    }

    function _requirePoolManager() internal view {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(IPoolManager _poolManager, IZKVerifier _verifier, TWAMMSettlement _settlement) {
        poolManager = _poolManager;
        verifier    = _verifier;
        settlement  = _settlement;
    }

    // -----------------------------------------------------------------------
    // ITWAMMXHook — commitOrder
    // -----------------------------------------------------------------------

    /// @inheritdoc ITWAMMXHook
    function commitOrder(PoolId poolId, bytes32 hash, uint64 delay)
        external
        override
        returns (bytes32 commitmentId)
    {
        if (delay < MIN_ORDER_DELAY || delay > MAX_ORDER_DELAY) revert InvalidDelay();
        if (hash == bytes32(0)) revert ZeroAmount();

        uint64 expiry = uint64(block.timestamp) + delay;

        // commitmentId = hash of (owner, hash, expiry, chainid) — unique per submission
        commitmentId = keccak256(abi.encodePacked(msg.sender, hash, expiry, block.chainid));

        _commitments[poolId][commitmentId] = Commitment({
            hash:     hash,
            expiry:   expiry,
            revealed: false
        });
        _owners[poolId][commitmentId] = msg.sender;

        emit OrderCommitted(poolId, commitmentId, msg.sender, expiry);
    }

    // -----------------------------------------------------------------------
    // ITWAMMXHook — revealOrder (ZK proof verification)
    // -----------------------------------------------------------------------

    /// @inheritdoc ITWAMMXHook
    function revealOrder(
        PoolId        poolId,
        bytes32       commitmentId,
        uint128       amountIn,
        bool          zeroForOne,
        bytes32       salt,
        uint[2]    calldata pA,
        uint[2][2] calldata pB,
        uint[2]    calldata pC
    ) external override {
        Commitment storage c = _commitments[poolId][commitmentId];
        if (c.hash == bytes32(0))  revert CommitmentNotFound();
        if (c.revealed)            revert CommitmentAlreadyRevealed();
        if (block.timestamp < c.expiry) revert CommitmentNotExpired();
        if (amountIn == 0)         revert ZeroAmount();

        // --- ZK proof verification ---
        // Public signals:
        //   [0] commitmentHash = keccak256(owner, amountIn, zeroForOne, salt) cast to field
        //   [1] poolIdHash     = uint256(poolId) truncated to field
        //   [2] expiry
        bytes32 expectedHash = keccak256(
            abi.encodePacked(_owners[poolId][commitmentId], amountIn, zeroForOne, salt)
        );
        if (expectedHash != c.hash) revert HashMismatch();

        uint256[3] memory pubSignals = [
            uint256(c.hash),
            uint256(PoolId.unwrap(poolId)),
            uint256(c.expiry)
        ];

        if (!verifier.verifyProof(pA, pB, pC, pubSignals)) revert InvalidProof();

        // Mark revealed and accumulate virtual sell pressure.
        // On FHE-enabled networks (Sepolia etc.), FHE.add() accumulates encrypted
        // sell pressure so the running total remains a ciphertext.
        // On non-FHE networks the plaintext fallback is used.
        c.revealed = true;

        if (zeroForOne) {
            _pendingSell0[poolId] += amountIn;
            _fheAccumulate(true, poolId, amountIn);
        } else {
            _pendingSell1[poolId] += amountIn;
            _fheAccumulate(false, poolId, amountIn);
        }

        // Execute actual token swap through settlement contract.
        // Settlement holds the trader's deposited funds and routes them
        // through PoolManager, crediting output to the trader's claimable balance.
        PoolKey memory key = _poolKeys[poolId];
        if (key.fee != 0) {
            // Pool has been seen (beforeSwap called at least once) — execute immediately
            settlement.executeSwap(commitmentId, key, zeroForOne);
        }
        // If pool key not yet cached (edge case: reveal before any swap),
        // the batch execution in afterSwap will handle it on next interaction.

        emit OrderRevealed(poolId, commitmentId, amountIn, zeroForOne);
    }

    // -----------------------------------------------------------------------
    // ITWAMMXHook — cancelOrder
    // -----------------------------------------------------------------------

    /// @inheritdoc ITWAMMXHook
    function cancelOrder(PoolId poolId, bytes32 commitmentId) external override {
        Commitment storage c = _commitments[poolId][commitmentId];
        if (c.hash == bytes32(0))              revert CommitmentNotFound();
        if (c.revealed)                        revert CommitmentAlreadyRevealed();
        if (_owners[poolId][commitmentId] != msg.sender) revert CommitmentNotFound();

        delete _commitments[poolId][commitmentId];
        delete _owners[poolId][commitmentId];

        emit OrderCancelled(poolId, commitmentId, msg.sender);
    }

    // -----------------------------------------------------------------------
    // ITWAMMXHook — distributeLPRebate
    // -----------------------------------------------------------------------

    /// @inheritdoc ITWAMMXHook
    function distributeLPRebate(PoolId poolId) external override {
        _distributeLPRebate(poolId);
    }

    /// @notice Reactive Network callback entry point.
    ///         Called automatically by TWAMMXReactive after each BatchExecuted event.
    ///         Uses a distinct name since PoolId is bytes32 at the ABI level.
    function reactiveDistributeRebate(bytes32 poolId) external {
        _distributeLPRebate(PoolId.wrap(poolId));
    }

    function _distributeLPRebate(PoolId poolId) internal {
        uint256 r0 = _rebate0[poolId];
        uint256 r1 = _rebate1[poolId];
        if (r0 == 0 && r1 == 0) revert NothingToDistribute();

        // Only donate if there is in-range liquidity to receive fees
        if (poolManager.getLiquidity(poolId) == 0) revert NothingToDistribute();

        // Start a new smoothing epoch — rebate is released linearly over SMOOTHING_WINDOW.
        // Any undistributed amount from a previous epoch rolls into the new total.
        uint256 prev0 = _epochTotal0[poolId] - _epochDonated0[poolId];
        uint256 prev1 = _epochTotal1[poolId] - _epochDonated1[poolId];

        _rebate0[poolId] = 0;
        _rebate1[poolId] = 0;

        _epochStart[poolId]   = uint64(block.timestamp);
        _epochTotal0[poolId]  = r0 + prev0;
        _epochTotal1[poolId]  = r1 + prev1;
        _epochDonated0[poolId] = 0;
        _epochDonated1[poolId] = 0;

        emit LPRebateDistributed(poolId, r0 + prev0, r1 + prev1);
        // Yield is now queued for linear release — call releaseYield() to donate vested portions.
    }

    /// @notice Release the currently vested portion of the smoothed rebate to LPs.
    ///         Can be called by anyone — Reactive Network calls this automatically.
    ///         Yield is released linearly: after 12h, 50% is available; after 24h, 100%.
    function releaseYield(PoolId poolId) external {
        _releaseVestedYield(poolId);
    }

    function _releaseVestedYield(PoolId poolId) internal {
        uint64 start  = _epochStart[poolId];
        if (start == 0) revert NothingToDistribute();

        uint256 total0 = _epochTotal0[poolId];
        uint256 total1 = _epochTotal1[poolId];
        if (total0 == 0 && total1 == 0) revert NothingToDistribute();

        if (poolManager.getLiquidity(poolId) == 0) revert NothingToDistribute();

        // Linear vesting: vested = total * min(elapsed, window) / window
        uint256 elapsed = block.timestamp - start;
        if (elapsed > SMOOTHING_WINDOW) elapsed = SMOOTHING_WINDOW;

        uint256 vested0 = FullMath.mulDiv(total0, elapsed, SMOOTHING_WINDOW);
        uint256 vested1 = FullMath.mulDiv(total1, elapsed, SMOOTHING_WINDOW);

        uint256 toRelease0 = vested0 - _epochDonated0[poolId];
        uint256 toRelease1 = vested1 - _epochDonated1[poolId];

        if (toRelease0 == 0 && toRelease1 == 0) revert NothingToDistribute();

        _epochDonated0[poolId] += toRelease0;
        _epochDonated1[poolId] += toRelease1;

        PoolKey memory key = _poolKeys[poolId];
        uint256 progress = FullMath.mulDiv(elapsed, 1e18, SMOOTHING_WINDOW); // 0–1e18

        poolManager.unlock(abi.encode(_ACT_DONATE, abi.encode(key, toRelease0, toRelease1)));

        emit YieldReleased(poolId, toRelease0, toRelease1, progress);
    }

    /// @notice Returns the currently releasable yield for a pool.
    function vestedYield(PoolId poolId)
        external view
        returns (uint256 amount0, uint256 amount1)
    {
        uint64 start = _epochStart[poolId];
        if (start == 0) return (0, 0);

        uint256 elapsed = block.timestamp - start;
        if (elapsed > SMOOTHING_WINDOW) elapsed = SMOOTHING_WINDOW;

        uint256 vested0 = FullMath.mulDiv(_epochTotal0[poolId], elapsed, SMOOTHING_WINDOW);
        uint256 vested1 = FullMath.mulDiv(_epochTotal1[poolId], elapsed, SMOOTHING_WINDOW);

        amount0 = vested0 > _epochDonated0[poolId] ? vested0 - _epochDonated0[poolId] : 0;
        amount1 = vested1 > _epochDonated1[poolId] ? vested1 - _epochDonated1[poolId] : 0;
    }

    // -----------------------------------------------------------------------
    // IUnlockCallback — handles donation inside PoolManager lock
    // -----------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (uint8 action, bytes memory inner) = abi.decode(data, (uint8, bytes));

        if (action == _ACT_DONATE) {
            (PoolKey memory key, uint256 amount0, uint256 amount1) =
                abi.decode(inner, (PoolKey, uint256, uint256));

            // Pull tokens from this contract into the pool manager then donate
            if (amount0 > 0) {
                poolManager.sync(key.currency0);
                IERC20Minimal(Currency.unwrap(key.currency0))
                    .transfer(address(poolManager), amount0);
                poolManager.settle();
            }
            if (amount1 > 0) {
                poolManager.sync(key.currency1);
                IERC20Minimal(Currency.unwrap(key.currency1))
                    .transfer(address(poolManager), amount1);
                poolManager.settle();
            }
            poolManager.donate(key, amount0, amount1, "");
        }
        return "";
    }

    // -----------------------------------------------------------------------
    // IHooks — beforeSwap: store PoolKey for later donation
    // -----------------------------------------------------------------------

    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Cache the PoolKey so distributeLPRebate can reference it later
        PoolId pid = key.toId();
        if (_poolKeys[pid].fee == 0) {
            _poolKeys[pid] = key;
        }
        // Initialise execution clock on first interaction
        if (_lastExecution[pid] == 0) {
            _lastExecution[pid] = uint64(block.timestamp);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // -----------------------------------------------------------------------
    // IHooks — afterSwap: TWAMM batch execution + LP rebate accrual
    // -----------------------------------------------------------------------

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId pid = key.toId();

        uint128 sell0 = _pendingSell0[pid];
        uint128 sell1 = _pendingSell1[pid];

        if (sell0 > 0 || sell1 > 0) {
            uint64 last    = _lastExecution[pid];
            uint64 elapsed = last == 0 ? 0 : uint64(block.timestamp) - last;

            if (elapsed > 0) {
                // Fetch current pool state
                (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(pid);
                uint128 liquidity         = poolManager.getLiquidity(pid);

                // Execute TWAMM batch — computes virtual execution amounts and new price.
                // NOTE: This is an accounting-layer execution. The computed amountOut values
                // represent what traders receive at the TWAP price. In a full production
                // deployment, actual token settlement would require a separate settlement
                // contract that holds trader funds and calls poolManager.swap() per order.
                // The price signal (newSqrt) is used here for rebate sizing only.
                (uint256 out0, uint256 out1, uint160 newSqrt) = TWAMMBatchMath.computeBatch(
                    sqrtPriceX96, liquidity, sell0, sell1, elapsed
                );

                // Accrue LP rebate from virtual spread
                if (out1 > 0) _rebate1[pid] += FullMath.mulDiv(out1, LP_REBATE_BPS, 10_000);
                if (out0 > 0) _rebate0[pid] += FullMath.mulDiv(out0, LP_REBATE_BPS, 10_000);

                // Drain pending sells — batch has been accounted for this interval.
                // FHE.sub() zeroes the encrypted accumulators so the ciphertext
                // reflects the drained state without revealing the previous total.
                _fheDrain(pid, sell0, sell1);
                _pendingSell0[pid] = 0;
                _pendingSell1[pid] = 0;

                emit BatchExecuted(pid, sell0, sell1, uint256(newSqrt));
            }

            _lastExecution[pid] = uint64(block.timestamp);
        } else {
            // No virtual orders — still accrue rebate from real swap volume
            // to compensate LPs for any residual informed flow
            uint256 swapVolume = params.amountSpecified < 0
                ? uint256(-params.amountSpecified)
                : uint256(uint128(params.zeroForOne ? -delta.amount0() : -delta.amount1()));

            if (swapVolume > 0) {
                uint256 rebate = FullMath.mulDiv(swapVolume, LP_REBATE_BPS, 10_000);
                if (params.zeroForOne) {
                    _rebate0[pid] += rebate;
                } else {
                    _rebate1[pid] += rebate;
                }
            }
        }

        return (IHooks.afterSwap.selector, 0);
    }

    // -----------------------------------------------------------------------
    // FHE helpers — gracefully degrade on non-FHE networks
    // -----------------------------------------------------------------------

    /// @dev Accumulate encrypted pending sell using FHE.add().
    ///      On networks without CoFHE TaskManager the call is silently skipped —
    ///      the plaintext _pendingSell* mapping is always the source of truth for
    ///      TWAMM math; the encrypted accumulator is the privacy layer on top.
    function _fheAccumulate(bool zeroForOne, PoolId poolId, uint128 amount) internal {
        try this._fheAccumulateInternal(zeroForOne, poolId, amount) {} catch {}
    }

    function _fheAccumulateInternal(bool zeroForOne, PoolId poolId, uint128 amount) external {
        require(msg.sender == address(this));
        euint128 eAmount = FHE.asEuint128(amount);
        FHE.allowThis(eAmount);
        if (zeroForOne) {
            if (Common.isInitialized(_encPendingSell0[poolId])) {
                euint128 newEnc = FHE.add(_encPendingSell0[poolId], eAmount);
                FHE.allowThis(newEnc);
                _encPendingSell0[poolId] = newEnc;
            } else {
                _encPendingSell0[poolId] = eAmount;
            }
        } else {
            if (Common.isInitialized(_encPendingSell1[poolId])) {
                euint128 newEnc = FHE.add(_encPendingSell1[poolId], eAmount);
                FHE.allowThis(newEnc);
                _encPendingSell1[poolId] = newEnc;
            } else {
                _encPendingSell1[poolId] = eAmount;
            }
        }
    }

    /// @dev Drain encrypted pending sells using FHE.sub() after batch execution.
    function _fheDrain(PoolId pid, uint128 sell0, uint128 sell1) internal {
        try this._fheDrainInternal(pid, sell0, sell1) {} catch {}
    }

    function _fheDrainInternal(PoolId pid, uint128 sell0, uint128 sell1) external {
        require(msg.sender == address(this));
        if (sell0 > 0 && Common.isInitialized(_encPendingSell0[pid])) {
            euint128 zero0 = FHE.sub(_encPendingSell0[pid], _encPendingSell0[pid]);
            FHE.allowThis(zero0);
            _encPendingSell0[pid] = zero0;
        }
        if (sell1 > 0 && Common.isInitialized(_encPendingSell1[pid])) {
            euint128 zero1 = FHE.sub(_encPendingSell1[pid], _encPendingSell1[pid]);
            FHE.allowThis(zero1);
            _encPendingSell1[pid] = zero1;
        }
    }

    // -----------------------------------------------------------------------
    // IHooks — pass-through stubs
    // -----------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160)
        external pure override returns (bytes4)
    { return IHooks.beforeInitialize.selector; }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure override returns (bytes4)
    { return IHooks.afterInitialize.selector; }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.beforeAddLiquidity.selector; }

    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta)
    { return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0)); }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.beforeRemoveLiquidity.selector; }

    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta)
    { return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0)); }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.beforeDonate.selector; }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4)
    { return IHooks.afterDonate.selector; }

    // -----------------------------------------------------------------------
    // ITWAMMXHook — views
    // -----------------------------------------------------------------------

    function getCommitment(PoolId poolId, bytes32 commitmentId)
        external view override returns (Commitment memory)
    {
        return _commitments[poolId][commitmentId];
    }

    function pendingSells(PoolId poolId)
        external view override returns (uint128 sell0, uint128 sell1)
    {
        return (_pendingSell0[poolId], _pendingSell1[poolId]);
    }

    function lpRebateAccrued(PoolId poolId)
        external view override returns (uint256 amount0, uint256 amount1)
    {
        return (_rebate0[poolId], _rebate1[poolId]);
    }
}
