// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title  TXPSwap
 * @author iYap Global
 * @notice Swap contract for TXP ↔ LCX, TXP ↔ YTC, and LCX ↔ YTC pairs.
 *         Mirrors all YapitSwap functionality (manual/DEX price feeds,
 *         platform fees, liquidity management, PancakeRouter passthrough)
 *         but transfers output tokens directly to the recipient — no auto-staking.
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

// ─── TXPSwap ──────────────────────────────────────────────────────────────────

contract TXPSwap is Pausable, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Addresses ──────────────────────────────────────────────────────────────

    address public WBNB         = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public pancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public USDT         = 0x55d398326f99059fF775485246999027B3197955;
    address public USDC         = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    address public TXP;
    address public YTC;
    address public LCX;

    address public treasury;
    uint256 public platformFee;

    uint256 constant MAX_FEE   = 100e18;
    uint256 constant PRECISION = 1e18;

    // ── Price feed ─────────────────────────────────────────────────────────────

    enum PriceFeed { DEX, MANUAL }

    /// @dev Extends YapitSwap's TokenFeed enum to include TXP.
    enum TokenFeed { TXP, YTC, LCX, USDT, USDC, WBNB, ROUTER, TREASURY }

    mapping(address => uint256)   public manualPrice;
    mapping(address => PriceFeed) public activePriceFeed;

    // ── Events ─────────────────────────────────────────────────────────────────

    event TXPSwapped(
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
        require(_txp      != address(0), "Invalid TXP");
        require(_ytc      != address(0), "Invalid YTC");
        require(_lcx      != address(0), "Invalid LCX");
        require(_treasury != address(0), "Invalid treasury");
        require(_platformFee <= MAX_FEE,  "Fee too high");

        TXP       = _txp;
        YTC       = _ytc;
        LCX       = _lcx;
        treasury  = _treasury;
        platformFee = _platformFee;

        // Default manual prices (owner should update these post-deploy)
        activePriceFeed[TXP] = PriceFeed.MANUAL;
        activePriceFeed[YTC] = PriceFeed.MANUAL;
        activePriceFeed[LCX] = PriceFeed.MANUAL;

        manualPrice[TXP] = 1e16;   // 1 USD = 100 TXP  (0.01 USD per token)
        manualPrice[YTC] = 1e16;   // 1 USD = 100 YTC  (0.01 USD per token)
        manualPrice[LCX] = 1e16;   // 1 USD = 100 LCX  (0.01 USD per token)
    }

    receive() external payable {}

    // ── Modifiers ──────────────────────────────────────────────────────────────

    modifier onlyValidUser(address _user) {
        require(_user != address(0), "!ZERO");
        require(msg.sender == _user,  "!USER");
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
        require(_newAddress != address(0), "Invalid address!");
        if      (feed == TokenFeed.TXP)      TXP          = _newAddress;
        else if (feed == TokenFeed.YTC)      YTC          = _newAddress;
        else if (feed == TokenFeed.LCX)      LCX          = _newAddress;
        else if (feed == TokenFeed.USDT)     USDT         = _newAddress;
        else if (feed == TokenFeed.USDC)     USDC         = _newAddress;
        else if (feed == TokenFeed.WBNB)     WBNB         = _newAddress;
        else if (feed == TokenFeed.ROUTER)   pancakeRouter = _newAddress;
        else if (feed == TokenFeed.TREASURY) treasury     = _newAddress;
        else revert("Invalid Feed!");
    }

    // ── Admin: liquidity management ────────────────────────────────────────────

    /**
     * @notice Deposit token or BNB liquidity so the contract can fulfil manual-price swaps.
     *         Pass `token = address(0)` with `msg.value` to deposit BNB.
     */
    function addManualLiquidity(address token, uint256 amount) external payable onlyOwner {
        require(amount > 0, "Invalid Amount!");
        if (token == address(0)) {
            require(amount == msg.value, "Invalid amount!");
            return;
        }
        require(msg.value == 0, "Invalid data!");
        IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);
    }

    /**
     * @notice Withdraw token or BNB liquidity from the contract.
     *         Pass `token = address(0)` to withdraw BNB.
     */
    function removeLiquidity(address token, address to, uint256 amount) external onlyOwner {
        require(to     != address(0), "Invalid Address");
        require(amount >  0,          "Invalid Amount");
        if (token == address(0)) {
            require(payable(to).send(amount), "BNB transfer failed!");
        } else {
            require(
                IERC20(token).balanceOf(address(this)) >= amount,
                "Insufficient balance"
            );
            SafeERC20.safeTransfer(IERC20(token), to, amount);
        }
    }

    // ── Admin: pricing ─────────────────────────────────────────────────────────

    /// @notice Set the manual price (in 1e18 USD) for a token.
    function setPrice(address _token, uint256 _price) external onlyOwner {
        require(_token != address(0), "Invalid address!");
        require(_price > 0,           "Invalid data!");
        manualPrice[_token] = _price;
    }

    /// @notice Switch between MANUAL and DEX price feed for a token.
    function setPriceFeed(address _token, PriceFeed feed) external onlyOwner {
        require(feed == PriceFeed.MANUAL || feed == PriceFeed.DEX, "Invalid Feed!");
        activePriceFeed[_token] = feed;
    }

    /// @notice Set the platform fee (e.g. 1e18 = 1%).
    function setPlatformFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "Invalid Fee!");
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

    /// @notice Returns the manual price for a token (reverts if unset / DEX mode).
    function getPrice(address token) public view returns (uint256) {
        if (activePriceFeed[token] == PriceFeed.MANUAL) {
            uint256 price = manualPrice[token];
            require(price > 0, "Manual price not set");
            return price;
        }
        return 0;
    }

    /**
     * @notice Calculate how many `_tokenOut` tokens will be received for
     *         `_amountIn` of `_tokenIn`, using the configured price feeds.
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
            uint256 priceIn  = getPrice(_tokenIn);
            uint256 priceOut = getPrice(_tokenOut);
            // amountOut = amountIn * priceIn / priceOut
            amountOut = (_amountIn * priceIn) / priceOut;
        } else if (_tokenIn == USDT || _tokenIn == USDC) {
            amountOut = (_amountIn * getPrice(_tokenOut)) / PRECISION;
        } else {
            if (_tokenIn == WBNB) {
                address[] memory path = new address[](2);
                path[0] = WBNB;
                path[1] = USDT;
                uint256 usdValue = IPancakeRouter02(pancakeRouter).getAmountsOut(_amountIn, path)[1];
                amountOut = (usdValue * getPrice(_tokenOut)) / PRECISION;
            } else {
                uint256 usdValue = (_amountIn * PRECISION) / getPrice(_tokenIn);
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
        require(_amountIn > 0,                            "Invalid amount!");
        require(_path.length == 2,                        "Invalid path!");
        require(_path[0] != address(0) && _path[1] != address(0), "Zero address in path!");
        require(_path[0] != _path[1],                     "Identical pair!");

        // Only allow pairs that involve at least one of TXP / YTC / LCX.
        require(
            _path[0] == TXP || _path[0] == YTC || _path[0] == LCX ||
            _path[1] == TXP || _path[1] == YTC || _path[1] == LCX,
            "Pair not supported!"
        );

        if (_path[0] != WBNB) require(msg.value == 0, "Invalid value!");

        uint256 fee;
        (_amountIn, fee) = this.getPlatformFee(_amountIn);

        // Collect input + fee from user (or BNB).
        if (_path[0] != WBNB) {
            IERC20(_path[0]).safeTransferFrom(_to, treasury,      fee);
            IERC20(_path[0]).safeTransferFrom(_to, address(this), _amountIn);
        } else {
            require(msg.value == _amountIn + fee, "BNB amount mismatch!");
            payable(treasury).transfer(fee);
        }

        require(
            activePriceFeed[_path[0]] == PriceFeed.MANUAL ||
            activePriceFeed[_path[1]] == PriceFeed.MANUAL,
            "priceFeed mismatch!"
        );

        uint256 amountOut = this.calcOutAmount(_path[0], _path[1], _amountIn);

        // Send output directly to recipient — no staking.
        if (_path[1] == WBNB) {
            require(address(this).balance >= amountOut, "Insufficient BNB liquidity!");
            payable(_to).transfer(amountOut);
        } else {
            require(
                IERC20(_path[1]).balanceOf(address(this)) >= amountOut,
                "Insufficient token liquidity!"
            );
            IERC20(_path[1]).safeTransfer(_to, amountOut);
        }

        emit TXPSwapped(_to, _path[0], _path[1], _amountIn, amountOut, fee, block.timestamp);
    }

    // ── PancakeRouter passthrough functions ───────────────────────────────────
    // These mirror YapitSwap's DEX-routed functions and can be used for any
    // token pair supported by PancakeSwap (including TXP/LCX/YTC if liquidity
    // is available on-chain).

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
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 fee;
        (amountIn, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountIn);
        amounts = IPancakeRouter02(_router).swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline);
        emit TXPSwapped(to, path[0], path[path.length - 1], amountIn, amounts[amounts.length - 1], fee, block.timestamp);
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
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 fee;
        (amountInMax, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountInMax);
        amounts = IPancakeRouter02(_router).swapTokensForExactTokens(amountOut, amountInMax, path, to, deadline);
        emit TXPSwapped(to, path[0], path[path.length - 1], amountInMax, amounts[amounts.length - 1], fee, block.timestamp);
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
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 fee;
        (amountIn, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountIn);
        amounts = IPancakeRouter02(_router).swapExactTokensForETH(amountIn, amountOutMin, path, to, deadline);
        emit TXPSwapped(to, path[0], path[path.length - 1], amountIn, amounts[amounts.length - 1], fee, block.timestamp);
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
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 fee;
        (amountInMax, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountInMax);
        amounts = IPancakeRouter02(_router).swapTokensForExactETH(amountOut, amountInMax, path, to, deadline);
        emit TXPSwapped(to, path[0], path[path.length - 1], amountInMax, amounts[amounts.length - 1], fee, block.timestamp);
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
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 amountIn = msg.value;
        uint256 fee;
        (amountIn, fee) = this.getPlatformFee(amountIn);
        amounts = IPancakeRouter02(_router).swapExactETHForTokens{value: amountIn}(amountOutMin, path, to, deadline);
        if (fee > 0) {
            require(address(this).balance >= fee, "Insufficient BNB for fee!");
            payable(treasury).transfer(fee);
        }
        emit TXPSwapped(to, path[0], path[path.length - 1], amountIn, amounts[amounts.length - 1], fee, block.timestamp);
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
        onlyValidUser(to)
        returns (uint256[] memory amounts)
    {
        uint256 amountIn = msg.value;
        uint256 fee;
        (amountIn, fee) = this.getPlatformFee(amountIn);
        amounts = IPancakeRouter02(_router).swapETHForExactTokens{value: amountIn}(amountOut, path, to, deadline);
        if (fee > 0) {
            require(address(this).balance >= fee, "Insufficient BNB for fee!");
            payable(treasury).transfer(fee);
        }
        emit TXPSwapped(to, path[0], path[path.length - 1], amountIn, amounts[amounts.length - 1], fee, block.timestamp);
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        IPancakeRouter02 _router,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external whenNotPaused nonReentrant onlyValidUser(to) {
        uint256 fee;
        (amountIn, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountIn);
        IPancakeRouter02(_router).swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, amountOutMin, path, to, deadline);
        emit TXPSwapped(to, path[0], path[path.length - 1], amountIn, amountOutMin, fee, block.timestamp);
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        IPancakeRouter02 _router,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable whenNotPaused nonReentrant onlyValidUser(to) {
        uint256 amountIn = msg.value;
        uint256 fee;
        (amountIn, fee) = this.getPlatformFee(amountIn);
        IPancakeRouter02(_router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amountIn}(amountOutMin, path, to, deadline);
        if (fee > 0) {
            require(address(this).balance >= fee, "Insufficient BNB for fee!");
            payable(treasury).transfer(fee);
        }
        emit TXPSwapped(to, path[0], path[path.length - 1], amountIn, amountOutMin, fee, block.timestamp);
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        IPancakeRouter02 _router,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external whenNotPaused nonReentrant onlyValidUser(to) {
        uint256 fee;
        (amountIn, fee) = _internalSupportingTransactions(to, path[0], address(_router), amountIn);
        IPancakeRouter02(_router).swapExactTokensForETHSupportingFeeOnTransferTokens(amountIn, amountOutMin, path, to, deadline);
        emit TXPSwapped(to, path[0], path[path.length - 1], amountIn, amountOutMin, fee, block.timestamp);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /**
     * @dev Pull tokens from the user, deduct platform fee, increase router allowance.
     *      Handles fee-on-transfer tokens by measuring actual balance delta.
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
            require(
                IERC20(_token).balanceOf(address(this)) >= _fee,
                "Insufficient fee liquidity!"
            );
            IERC20(_token).safeTransfer(treasury, _fee);
        }
        IERC20(_token).safeIncreaseAllowance(_router, amount);
    }
}
