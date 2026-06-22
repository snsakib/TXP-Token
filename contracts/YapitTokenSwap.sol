// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title  YapitTokenSwap
 * @author iYap Global
 * @notice Unified swap contract for TXP ↔ LCX, TXP ↔ YTC, and LCX ↔ YTC pairs.
 *         Replaces both YapitSwap and TXPSwap: supports manual/DEX price feeds,
 *         platform fees, and PancakeRouter passthrough — no staking.
 *         Output tokens are always sent directly to the recipient.
 *
 * @dev    This variant of TokenSwap applies the following audit fixes:
 *           - Fix 1: corrected (previously inverted) stablecoin / WBNB pricing math.
 *           - Fix 2: getPrice() reverts cleanly instead of returning 0 for non-manual feeds.
 *           - Fix 4: PancakeRouter passthrough functions are restricted to the
 *                    configured `pancakeRouter` via the `onlyKnownRouter` guard.
 */

// ─── OpenZeppelin imports ─────────────────────────────────────────────────────

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// ─── PancakeRouter interfaces ─────────────────────────────────────────────────

interface IPancakeRouter01 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA, address tokenB,
        uint256 amountADesired, uint256 amountBDesired,
        uint256 amountAMin, uint256 amountBMin,
        address to, uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function addLiquidityETH(
        address token, uint256 amountTokenDesired,
        uint256 amountTokenMin, uint256 amountETHMin,
        address to, uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
    function swapTokensForExactTokens(uint256 amountOut, uint256 amountInMax, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory amounts);
    function swapTokensForExactETH(uint256 amountOut, uint256 amountInMax, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
    function swapExactTokensForETH(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
    function swapETHForExactTokens(uint256 amountOut, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
    function quote(uint256 amountA, uint256 reserveA, uint256 reserveB) external pure returns (uint256 amountB);
    function getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256 amountOut);
    function getAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) external pure returns (uint256 amountIn);
}

interface IPancakeRouter02 is IPancakeRouter01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(address token, uint256 liquidity, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline) external returns (uint256 amountETH);
    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(address token, uint256 liquidity, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline, bool approveMax, uint8 v, bytes32 r, bytes32 s) external returns (uint256 amountETH);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
}

// ─── YapitTokenSwap ───────────────────────────────────────────────────────────

contract YapitTokenSwap is Pausable, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    error InvalidTxp();
    error InvalidYtc();
    error InvalidLcx();
    error InvalidTreasury();
    error FeeTooHigh();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidData();
    error InvalidFeed();
    error InvalidFee();
    error ManualPriceNotSet();
    error InvalidUser();
    error ZeroAddress();
    error PairNotSupported();
    error InvalidPath();
    error IdenticalPair();
    error ZeroAddressInPath();
    error InvalidValue();
    error BnbAmountMismatch();
    error PriceFeedMismatch();
    error InsufficientBnbLiquidity();
    error InsufficientTokenLiquidity();
    error BnbTransferFailed();
    error InsufficientFeeLiquidity();
    error InvalidRouter();

    // ── Addresses ──────────────────────────────────────────────────────────────

    address public WBNB          = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address public pancakeRouter = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address public USDT          = 0x337610d27c682E347C9cD60BD4b3b107C9d34dDd;
    address public USDC          = 0x89C8da7569085D406800C473619d0c6B7AC0CE8E;

    address public TXP;
    address public YTC;
    address public LCX;

    address public treasury;
    uint256 public platformFee;

    uint256 constant MAX_FEE   = 100e18;
    uint256 constant PRECISION = 1e18;

    // ── Price feed ─────────────────────────────────────────────────────────────

    enum PriceFeed { DEX, MANUAL }

    enum TokenFeed { TXP, YTC, LCX, USDT, USDC, WBNB, ROUTER, TREASURY }

    mapping(address => uint256)   public manualPrice;
    mapping(address => PriceFeed) public activePriceFeed;

    // ── Events ─────────────────────────────────────────────────────────────────

    event TokenSwapped(
        address indexed user,
        address indexed assetIn,
        address indexed assetOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        uint256 timestamp
    );

    // ── Constructor ────────────────────────────────────────────────────────────

    /**
     * @param _owner       Contract owner / admin address.
     * @param _txp         TXP token address.
     * @param _ytc         YTC token address.
     * @param _lcx         LCX token address.
     * @param _treasury    Address that receives platform fees.
     * @param _platformFee Platform fee in 1e18 precision (e.g. 1e18 = 1%).
     */
    constructor(
        address _owner,
        address _txp,
        address _ytc,
        address _lcx,
        address _treasury,
        uint256 _platformFee
    ) Ownable(_owner) {
        if (_txp == address(0)) revert InvalidTxp();
        if (_ytc == address(0)) revert InvalidYtc();
        if (_lcx == address(0)) revert InvalidLcx();
        if (_treasury == address(0)) revert InvalidTreasury();
        if (_platformFee > MAX_FEE) revert FeeTooHigh();

        TXP       = _txp;
        YTC       = _ytc;
        LCX       = _lcx;
        treasury  = _treasury;
        platformFee = _platformFee;

        // Default manual prices (owner should update these post-deploy).
        activePriceFeed[TXP] = PriceFeed.MANUAL;
        activePriceFeed[YTC] = PriceFeed.MANUAL;
        activePriceFeed[LCX] = PriceFeed.MANUAL;

        manualPrice[TXP] = 100e18;  // 100 USD per TXP
        manualPrice[YTC] = 10e18;   // 10 USD per YTC
        manualPrice[LCX] = 1e18;    // 1 USD per LCX
    }

    receive() external payable {}

    // ── Modifiers ──────────────────────────────────────────────────────────────

    modifier onlyValidUser(address _user) {
        if (_user == address(0)) revert ZeroAddress();
        if (msg.sender != _user) revert InvalidUser();
        _;
    }

    /**
     * @dev Fix 4: restrict PancakeRouter passthrough functions to the configured
     *      `pancakeRouter`, preventing a caller from supplying a malicious router
     *      that could siphon the allowance granted during the swap.
     */
    modifier onlyKnownRouter(IPancakeRouter02 _router) {
        if (address(_router) != pancakeRouter) revert InvalidRouter();
        _;
    }

    // ── Admin: pause ───────────────────────────────────────────────────────────

    function pause()   external onlyOwner { _pause();   }
    function unPause() external onlyOwner { _unpause(); }

    // ── Admin: token & address management ─────────────────────────────────────

    /**
     * @notice Update any tracked address (tokens, router, treasury).
     */
    function updateTokens(address _newAddress, TokenFeed feed) external onlyOwner {
        if (_newAddress == address(0)) revert InvalidAddress();
        if      (feed == TokenFeed.TXP)      TXP          = _newAddress;
        else if (feed == TokenFeed.YTC)      YTC          = _newAddress;
        else if (feed == TokenFeed.LCX)      LCX          = _newAddress;
        else if (feed == TokenFeed.USDT)     USDT         = _newAddress;
        else if (feed == TokenFeed.USDC)     USDC         = _newAddress;
        else if (feed == TokenFeed.WBNB)     WBNB         = _newAddress;
        else if (feed == TokenFeed.ROUTER)   pancakeRouter = _newAddress;
        else if (feed == TokenFeed.TREASURY) treasury     = _newAddress;
        else revert InvalidFeed();
    }

    // ── Admin: liquidity management ────────────────────────────────────────────

    /**
     * @notice Deposit token or BNB liquidity so the contract can fulfil manual-price swaps.
     *         Pass `token = address(0)` with `msg.value` to deposit BNB.
     */
    function addManualLiquidity(address token, uint256 amount) external payable onlyOwner {
        if (amount == 0) revert InvalidAmount();
        if (token == address(0)) {
            if (amount != msg.value) revert InvalidAmount();
            return;
        }
        if (msg.value != 0) revert InvalidData();
        IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);
    }

    /**
     * @notice Withdraw token or BNB liquidity from the contract.
     *         Pass `token = address(0)` to withdraw BNB.
     */
    function removeLiquidity(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0) revert InvalidAmount();
        if (token == address(0)) {
            if (!payable(to).send(amount)) revert BnbTransferFailed();
        } else {
            if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientTokenLiquidity();
            SafeERC20.safeTransfer(IERC20(token), to, amount);
        }
    }

    // ── Admin: pricing ─────────────────────────────────────────────────────────

    /// @notice Set the manual price (in 1e18 USD) for a token.
    function setPrice(address _token, uint256 _price) external onlyOwner {
        if (_token == address(0)) revert InvalidAddress();
        if (_price == 0) revert InvalidData();
        manualPrice[_token] = _price;
    }

    /// @notice Switch between MANUAL and DEX price feed for a token.
    function setPriceFeed(address _token, PriceFeed feed) external onlyOwner {
        if (feed != PriceFeed.MANUAL && feed != PriceFeed.DEX) revert InvalidFeed();
        activePriceFeed[_token] = feed;
    }

    /// @notice Set the platform fee (e.g. 1e18 = 1%).
    function setPlatformFee(uint256 _fee) external onlyOwner {
        if (_fee > MAX_FEE) revert InvalidFee();
        platformFee = _fee;
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    /// @notice Returns the post-fee amount and the fee amount for a given input.
    function getPlatformFee(uint256 _amountIn)
        external
        view
        returns (uint256 amountIn, uint256 feeAmount)
    {
        feeAmount = (_amountIn * platformFee) / MAX_FEE;
        amountIn  = _amountIn - feeAmount;
    }

    /**
     * @notice Returns the manual price for a token.
     * @dev    Fix 2: reverts with `ManualPriceNotSet` when the token is not on a
     *         manual feed or has no price configured, instead of returning 0.
     *         All call sites require a positive manual price, so a 0 return would
     *         previously cause a silent division-by-zero panic.
     */
    function getPrice(address token) public view returns (uint256) {
        if (activePriceFeed[token] != PriceFeed.MANUAL) revert ManualPriceNotSet();
        uint256 price = manualPrice[token];
        if (price == 0) revert ManualPriceNotSet();
        return price;
    }

    /**
     * @notice Calculate how many `_tokenOut` tokens will be received for
     *         `_amountIn` of `_tokenIn`, using the configured price feeds.
     *         Uses cross-rate formula: amountOut = amountIn * priceIn / priceOut.
     * @dev    Fix 1: corrects the previously inverted multiply/divide on the
     *         stablecoin-in, WBNB-in, and token-to-WBNB routes.
     */
    function calcOutAmount(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256 amountOut) {
        if (
            activePriceFeed[_tokenIn] == PriceFeed.MANUAL &&
            _tokenOut != WBNB
        ) {
            // Both tokens have a manual USD price — cross-rate conversion.
            // getPrice reverts (Fix 2) if either side is not on a manual feed.
            uint256 priceIn  = getPrice(_tokenIn);
            uint256 priceOut = getPrice(_tokenOut);
            amountOut = (_amountIn * priceIn) / priceOut;
        } else if (_tokenIn == USDT || _tokenIn == USDC) {
            // Stable in ($1) -> token: tokensOut = usd * PRECISION / priceOut.
            amountOut = (_amountIn * PRECISION) / getPrice(_tokenOut);
        } else {
            if (_tokenIn == WBNB) {
                address[] memory path = new address[](2);
                path[0] = WBNB;
                path[1] = USDT;
                uint256 usdValue = IPancakeRouter02(pancakeRouter).getAmountsOut(_amountIn, path)[1];
                // usd -> token: tokensOut = usd * PRECISION / priceOut.
                amountOut = (usdValue * PRECISION) / getPrice(_tokenOut);
            } else {
                // token -> WBNB: usd = amountIn * priceIn / PRECISION.
                uint256 usdValue = (_amountIn * getPrice(_tokenIn)) / PRECISION;
                address[] memory path = new address[](2);
                path[0] = USDT;
                path[1] = WBNB;
                amountOut = IPancakeRouter02(pancakeRouter).getAmountsOut(usdValue, path)[1];
            }
        }
    }

    // ── Core swap: manual-price pairs (TXP ↔ LCX, TXP ↔ YTC, LCX ↔ YTC) ────

    /**
     * @notice Swap between any two of {TXP, YTC, LCX} using manual price feeds,
     *         or between those tokens and BNB.
     *         Output tokens are sent directly to `_to` — no auto-staking.
     *
     * @param _path     [tokenIn, tokenOut]. Use WBNB address for native BNB.
     * @param _amountIn Gross input amount (fee is deducted from this).
     * @param _to       Recipient of the output tokens (must be msg.sender).
     */
    function swap(
        address[] memory _path,
        uint256 _amountIn,
        address _to
    ) external payable whenNotPaused nonReentrant onlyValidUser(_to) {
        if (_amountIn == 0) revert InvalidAmount();
        if (_path.length != 2) revert InvalidPath();
        if (_path[0] == address(0) || _path[1] == address(0)) revert ZeroAddressInPath();
        if (_path[0] == _path[1]) revert IdenticalPair();

        // Only allow pairs that involve at least one of TXP / YTC / LCX.
        if (
            _path[0] != TXP && _path[0] != YTC && _path[0] != LCX &&
            _path[1] != TXP && _path[1] != YTC && _path[1] != LCX
        ) revert PairNotSupported();

        if (_path[0] != WBNB && msg.value != 0) revert InvalidValue();

        uint256 fee;
        (_amountIn, fee) = this.getPlatformFee(_amountIn);

        // Collect input + fee from user (or BNB).
        if (_path[0] != WBNB) {
            IERC20(_path[0]).safeTransferFrom(_to, treasury,      fee);
            IERC20(_path[0]).safeTransferFrom(_to, address(this), _amountIn);
        } else {
            if (msg.value != _amountIn + fee) revert BnbAmountMismatch();
            payable(treasury).transfer(fee);
        }

        if (
            activePriceFeed[_path[0]] != PriceFeed.MANUAL &&
            activePriceFeed[_path[1]] != PriceFeed.MANUAL
        ) revert PriceFeedMismatch();

        uint256 amountOut = this.calcOutAmount(_path[0], _path[1], _amountIn);

        // Send output directly to recipient.
        if (_path[1] == WBNB) {
            if (address(this).balance < amountOut) revert InsufficientBnbLiquidity();
            payable(_to).transfer(amountOut);
        } else {
            if (IERC20(_path[1]).balanceOf(address(this)) < amountOut) revert InsufficientTokenLiquidity();
            IERC20(_path[1]).safeTransfer(_to, amountOut);
        }

        emit TokenSwapped(_to, _path[0], _path[1], _amountIn, amountOut, fee, block.timestamp);
    }

    // ── PancakeRouter passthrough functions ───────────────────────────────────
    // Used for any token pair supported by PancakeSwap (including TXP/LCX/YTC
    // if liquidity is available on-chain). Platform fee is deducted first.
    // Fix 4: every passthrough is restricted to the configured `pancakeRouter`.

    function swapExactTokenForTokens(
        IPancakeRouter02 _router,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        whenNotPaused
        nonReentrant
        onlyKnownRouter(_router)
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 fee;
        (amountIn, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountIn);
        amounts = IPancakeRouter02(_router).swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
        emit TokenSwapped(to, path[0], path[path.length - 1], amountIn, amounts[amounts.length - 1], fee, block.timestamp);
    }

    function swapTokensForExactTokens(
        IPancakeRouter02 _router,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        whenNotPaused
        nonReentrant
        onlyKnownRouter(_router)
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 fee;
        (amountInMax, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountInMax);
        amounts = IPancakeRouter02(_router).swapTokensForExactTokens(amountOut, amountInMax, path, to, deadline);
        emit TokenSwapped(to, path[0], path[path.length - 1], amountInMax, amounts[amounts.length - 1], fee, block.timestamp);
    }

    function swapExactTokensForETH(
        IPancakeRouter02 _router,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        whenNotPaused
        nonReentrant
        onlyKnownRouter(_router)
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 fee;
        (amountIn, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountIn);
        amounts = IPancakeRouter02(_router).swapExactTokensForETH(amountIn, amountOutMin, path, to, deadline);
        emit TokenSwapped(to, path[0], path[path.length - 1], amountIn, amounts[amounts.length - 1], fee, block.timestamp);
    }

    function swapTokensForExactETH(
        IPancakeRouter02 _router,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        whenNotPaused
        nonReentrant
        onlyKnownRouter(_router)
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 fee;
        (amountInMax, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountInMax);
        amounts = IPancakeRouter02(_router).swapTokensForExactETH(amountOut, amountInMax, path, to, deadline);
        emit TokenSwapped(to, path[0], path[path.length - 1], amountInMax, amounts[amounts.length - 1], fee, block.timestamp);
    }

    function swapExactETHForTokens(
        IPancakeRouter02 _router,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        whenNotPaused
        nonReentrant
        onlyKnownRouter(_router)
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 amountIn = msg.value;
        uint256 fee;
        (amountIn, fee) = this.getPlatformFee(amountIn);
        amounts = IPancakeRouter02(_router).swapExactETHForTokens{value: amountIn}(amountOutMin, path, to, deadline);
        if (fee > 0) {
            if (address(this).balance < fee) revert InsufficientBnbLiquidity();
            payable(treasury).transfer(fee);
        }
        emit TokenSwapped(to, path[0], path[path.length - 1], amountIn, amounts[amounts.length - 1], fee, block.timestamp);
    }

    function swapETHForExactTokens(
        IPancakeRouter02 _router,
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        whenNotPaused
        nonReentrant
        onlyKnownRouter(_router)
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 amountIn = msg.value;
        uint256 fee;
        (amountIn, fee) = this.getPlatformFee(amountIn);
        amounts = IPancakeRouter02(_router).swapETHForExactTokens{value: amountIn}(amountOut, path, to, deadline);
        if (fee > 0) {
            if (address(this).balance < fee) revert InsufficientBnbLiquidity();
            payable(treasury).transfer(fee);
        }
        emit TokenSwapped(to, path[0], path[path.length - 1], amountIn, amounts[amounts.length - 1], fee, block.timestamp);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        IPancakeRouter02 _router,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external whenNotPaused nonReentrant onlyKnownRouter(_router) onlyValidUser(to) {
        uint256 fee;
        (amountIn, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountIn);
        IPancakeRouter02(_router).swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, amountOutMin, path, to, deadline);
        emit TokenSwapped(to, path[0], path[path.length - 1], amountIn, amountOutMin, fee, block.timestamp);
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        IPancakeRouter02 _router,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant onlyKnownRouter(_router) onlyValidUser(to) {
        uint256 amountIn = msg.value;
        uint256 fee;
        (amountIn, fee) = this.getPlatformFee(amountIn);
        IPancakeRouter02(_router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(amountOutMin, path, to, deadline);
        if (fee > 0) {
            if (address(this).balance < fee) revert InsufficientBnbLiquidity();
            payable(treasury).transfer(fee);
        }
        emit TokenSwapped(to, path[0], path[path.length - 1], amountIn, amountOutMin, fee, block.timestamp);
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        IPancakeRouter02 _router,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external whenNotPaused nonReentrant onlyKnownRouter(_router) onlyValidUser(to) {
        uint256 fee;
        (amountIn, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountIn);
        IPancakeRouter02(_router).swapExactTokensForETHSupportingFeeOnTransferTokens(amountIn, amountOutMin, path, to, deadline);
        emit TokenSwapped(to, path[0], path[path.length - 1], amountIn, amountOutMin, fee, block.timestamp);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /**
     * @dev Pull tokens from the user, deduct platform fee to treasury, and
     *      increase router allowance. Measures actual balance delta to handle
     *      fee-on-transfer tokens correctly.
     */
    function _internalSupportingTransactions(
        address _user,
        address _token,
        address _router,
        uint256 _amount
    ) private returns (uint256 amount, uint256 _fee) {
        uint256 before = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransferFrom(_user, address(this), _amount);
        uint256 delta  = IERC20(_token).balanceOf(address(this)) - before;

        (amount, _fee) = this.getPlatformFee(delta);

        if (_fee > 0) {
            if (IERC20(_token).balanceOf(address(this)) < _fee) revert InsufficientFeeLiquidity();
            IERC20(_token).safeTransfer(treasury, _fee);
        }
        IERC20(_token).safeIncreaseAllowance(_router, amount);
    }
}
