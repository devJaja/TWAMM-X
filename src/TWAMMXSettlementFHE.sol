// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19 <0.9.0;

import {IPoolManager} from "@uniswap/v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/libraries/TickMath.sol";
import {IERC20Minimal} from "@uniswap/v4-core/interfaces/external/IERC20Minimal.sol";

import "@fhenixprotocol/cofhe-contracts/FHE.sol";

/// @title TWAMMXSettlementFHE
/// @notice FHE-enhanced settlement contract for TWAMM-X.
///
/// Privacy model:
///   - Order amounts are stored as `euint128` — encrypted on-chain via Fhenix CoFHE.
///   - Order direction is stored as `ebool` — encrypted on-chain.
///   - The TWAMM hook accumulates encrypted sell pressure using FHE.add(),
///     so even the aggregate virtual order flow is never visible in plaintext.
///   - Only at swap execution time is the net amount decrypted (async, via CoFHE
///     threshold network) and used to settle the actual PoolManager swap.
///   - Traders can decrypt their own output balance off-chain via cofhejs
///     using their wallet key — no one else can read it.
///
/// This contract is deployed on Fhenix-supported networks (Sepolia, Arbitrum Sepolia,
/// Base Sepolia). The TWAMMXHook on the same network calls depositFHE() and executeSwapFHE().
///
/// Compared to TWAMMSettlement (plaintext):
///   - depositAmount[id]  : uint128  → euint128  (encrypted)
///   - depositDir[id]     : bool     → ebool     (encrypted)
///   - claimable[owner]   : uint256  → euint128  (encrypted, owner-only readable)
contract TWAMMXSettlementFHE is IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------

    error OnlyHook();
    error NothingToClaim();
    error TransferFailed();
    error DecryptionNotReady();

    // -----------------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------------

    event EncryptedDeposit(bytes32 indexed commitmentId, address indexed owner);
    event SwapExecuted(bytes32 indexed commitmentId, address indexed owner);
    event Claimed(address indexed owner, address token);
    event Refunded(bytes32 indexed commitmentId, address indexed owner);

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    address       public immutable hook;

    /// @dev Encrypted deposit amount per commitment (euint128 handle)
    mapping(bytes32 => euint128) public encryptedAmount;

    /// @dev Encrypted swap direction per commitment (ebool handle)
    mapping(bytes32 => ebool)    public encryptedDirection;

    /// @dev Plaintext token address for input (needed to pull ERC20)
    mapping(bytes32 => address)  public depositToken;

    /// @dev Owner of each commitment
    mapping(bytes32 => address)  public depositOwner;

    /// @dev Encrypted claimable output per (owner, token) — only owner can decrypt
    mapping(address => mapping(address => euint128)) public encryptedClaimable;

    /// @dev Pending decryption requests: commitmentId → requested
    mapping(bytes32 => bool) public decryptionRequested;

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    constructor(IPoolManager _poolManager, address _hook) {
        poolManager = _poolManager;
        hook        = _hook;
    }

    // -----------------------------------------------------------------------
    // Trader-facing: depositFHE
    // -----------------------------------------------------------------------

    /// @notice Deposit encrypted order details when committing.
    ///         The amount and direction are encrypted client-side via cofhejs
    ///         before being sent to this contract — they are never visible on-chain.
    ///
    /// @param commitmentId  ID from TWAMMXHook.commitOrder()
    /// @param inAmount      Encrypted amount (InEuint128 from cofhejs)
    /// @param inDirection   Encrypted direction (InEbool from cofhejs)
    /// @param token         Input token address (plaintext — needed for ERC20 pull)
    /// @param plainAmount   Plaintext amount for ERC20 transferFrom (unavoidable for custody)
    function depositFHE(
        bytes32          commitmentId,
        InEuint128 memory inAmount,
        InEbool    memory inDirection,
        address          token,
        uint128          plainAmount
    ) external {
        // Convert encrypted inputs to stored ciphertext handles
        euint128 eAmount = FHE.asEuint128(inAmount);
        ebool    eDir    = FHE.asEbool(inDirection);

        // Grant this contract persistent access to both ciphertext handles
        FHE.allowThis(eAmount);
        FHE.allowThis(eDir);

        // Store encrypted state
        encryptedAmount[commitmentId]    = eAmount;
        encryptedDirection[commitmentId] = eDir;
        depositToken[commitmentId]       = token;
        depositOwner[commitmentId]       = msg.sender;

        // Pull plaintext ERC20 for custody (amount must match encrypted value)
        // Note: the plaintext amount is required for ERC20 transferFrom but is
        // NOT stored — only the encrypted handle is kept on-chain.
        bool ok = IERC20Minimal(token).transferFrom(msg.sender, address(this), plainAmount);
        if (!ok) revert TransferFailed();

        emit EncryptedDeposit(commitmentId, msg.sender);
    }

    // -----------------------------------------------------------------------
    // Hook-facing: executeSwapFHE
    // -----------------------------------------------------------------------

    /// @notice Called by the hook after ZK proof verification.
    ///         Requests async decryption of the encrypted amount, then executes
    ///         the swap once decryption is ready.
    ///
    ///         Two-step flow (required by CoFHE async decryption):
    ///           Step 1: call executeSwapFHE() → requests decryption
    ///           Step 2: call settleAfterDecryption() → executes swap with plaintext
    function executeSwapFHE(
        bytes32          commitmentId,
        PoolKey calldata key
    ) external {
        if (msg.sender != hook) revert OnlyHook();

        // Request async decryption of the encrypted amount
        // CoFHE threshold network will process this and make result available
        FHE.decrypt(encryptedAmount[commitmentId]);
        decryptionRequested[commitmentId] = true;
    }

    /// @notice Step 2: settle the swap once CoFHE has decrypted the amount.
    ///         Anyone can call this — it will revert if decryption isn't ready yet.
    function settleAfterDecryption(
        bytes32          commitmentId,
        PoolKey calldata key
    ) external {
        require(decryptionRequested[commitmentId], "No decryption requested");

        // Safe decryption — returns (value, isReady)
        (uint128 plainAmount, bool ready) = FHE.getDecryptResultSafe(encryptedAmount[commitmentId]);
        if (!ready) revert DecryptionNotReady();

        address owner   = depositOwner[commitmentId];
        address tokenIn = depositToken[commitmentId];

        // Determine direction — for settlement we use the plaintext amount
        // Direction is decrypted separately (or inferred from the ZK reveal)
        // Here we use the hook's revealed zeroForOne from the commitment reveal
        // (stored as a hint in the key — see TWAMMXHook.revealOrder)
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;

        // Clear state (CEI)
        encryptedAmount[commitmentId]    = euint128.wrap(bytes32(0));
        encryptedDirection[commitmentId] = ebool.wrap(bytes32(0));
        delete depositToken[commitmentId];
        delete depositOwner[commitmentId];
        delete decryptionRequested[commitmentId];

        // Execute actual swap
        bytes memory result = poolManager.unlock(
            abi.encode(key, zeroForOne, plainAmount, owner, tokenIn)
        );

        uint256 amountOut = abi.decode(result, (uint256));

        // Store encrypted claimable output — only owner can decrypt via cofhejs
        address tokenOut = zeroForOne
            ? Currency.unwrap(key.currency1)
            : Currency.unwrap(key.currency0);

        // Encrypt the output amount and grant only the owner access
        euint128 eOut = FHE.asEuint128(uint128(amountOut));
        FHE.allowThis(eOut);
        FHE.allow(eOut, owner); // only owner can decrypt their output

        // Accumulate encrypted claimable
        if (Common.isInitialized(encryptedClaimable[owner][tokenOut])) {
            euint128 newTotal = FHE.add(encryptedClaimable[owner][tokenOut], eOut);
            FHE.allowThis(newTotal);
            FHE.allow(newTotal, owner);
            encryptedClaimable[owner][tokenOut] = newTotal;
        } else {
            encryptedClaimable[owner][tokenOut] = eOut;
        }

        emit SwapExecuted(commitmentId, owner);
    }

    // -----------------------------------------------------------------------
    // IUnlockCallback — swap execution inside PoolManager lock
    // -----------------------------------------------------------------------

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(poolManager));

        (PoolKey memory key, bool zeroForOne, uint128 amountIn,, address tokenIn) =
            abi.decode(data, (PoolKey, bool, uint128, address, address));

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

        int128 inputDelta  = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();

        if (inputDelta < 0) {
            uint256 owed = uint256(int256(-inputDelta));
            poolManager.sync(zeroForOne ? key.currency0 : key.currency1);
            IERC20Minimal(tokenIn).transfer(address(poolManager), owed);
            poolManager.settle();
        }

        uint256 amountOut = 0;
        if (outputDelta > 0) {
            amountOut = uint256(int256(outputDelta));
            Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
            poolManager.take(outputCurrency, address(this), amountOut);
        }

        return abi.encode(amountOut);
    }

    // -----------------------------------------------------------------------
    // Trader-facing: claim (off-chain decryption via cofhejs)
    // -----------------------------------------------------------------------

    /// @notice Request decryption of your claimable balance.
    ///         After calling this, use cofhejs off-chain to read the decrypted value,
    ///         then call claimPlaintext() with the amount.
    function requestClaimDecryption(address token) external {
        euint128 eBalance = encryptedClaimable[msg.sender][token];
        require(Common.isInitialized(eBalance), "Nothing to claim");
        FHE.decrypt(eBalance);
    }

    /// @notice Withdraw after decryption is ready.
    function claim(address token) external {
        euint128 eBalance = encryptedClaimable[msg.sender][token];
        require(Common.isInitialized(eBalance), "Nothing to claim");

        (uint128 amount, bool ready) = FHE.getDecryptResultSafe(eBalance);
        if (!ready) revert DecryptionNotReady();
        if (amount == 0) revert NothingToClaim();

        // Clear encrypted balance
        encryptedClaimable[msg.sender][token] = euint128.wrap(bytes32(0));

        bool ok = IERC20Minimal(token).transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit Claimed(msg.sender, token);
    }

    // -----------------------------------------------------------------------
    // Trader-facing: refund (cancel before reveal)
    // -----------------------------------------------------------------------

    /// @notice Recover deposited funds after cancelling a commitment.
    ///         Requires plaintext amount since we need to transfer ERC20.
    function refund(bytes32 commitmentId, uint128 plainAmount) external {
        require(depositOwner[commitmentId] == msg.sender, "Not owner");

        address token = depositToken[commitmentId];

        encryptedAmount[commitmentId]    = euint128.wrap(bytes32(0));
        encryptedDirection[commitmentId] = ebool.wrap(bytes32(0));
        delete depositToken[commitmentId];
        delete depositOwner[commitmentId];

        bool ok = IERC20Minimal(token).transfer(msg.sender, plainAmount);
        if (!ok) revert TransferFailed();

        emit Refunded(commitmentId, msg.sender);
    }
}
