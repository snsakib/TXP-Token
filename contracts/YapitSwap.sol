// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IPancakeRouter01 {
    function factory() external pure returns (address);

    function WETH() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
        external
        payable
        returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactETH(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapETHForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function quote(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountOut);

    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) external pure returns (uint256 amountIn);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);

    function getAmountsIn(
        uint256 amountOut,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

interface IPancakeRouter02 is IPancakeRouter01 {
    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountETH);

    function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline,
        bool approveMax,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 amountETH);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

contract YapitSwap is Pausable, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    address public WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public pancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    address public YTC;
    address public LCX;
    uint256 public platformFee;
    uint256 public unStakeFee;
    address public treasury;
    uint256 constant MAX_FEE = 100e18;
    uint256 constant PRECISION = 1E18;

    enum PriceFeed {
        DEX,
        MANUAL
    }

    enum TokenFeed {
        YTC,
        LCX,
        USDT,
        USDC,
        WBNB,
        ROUTER,
        TREASURY
    }

    struct StakeFeed {
        uint256 min;
        uint256 max;
        uint256 rate;
        uint256 period;
    }

    struct userStake {
        address stakeToken;
        uint256 stakeAmount;
        uint256 stakeTime;
        uint256 endTime;
        uint256 rewardAmount;
        uint256 lastClaim;
    }

    mapping(address => uint256) public manualPrice;
    mapping(address => PriceFeed) public activePriceFeed;
    mapping(address => StakeFeed) public stakesFeed;
    mapping(address => mapping(uint256 => userStake)) public stakerInfo;
    mapping(address => uint256) public stakeIds;

    event YapitSwapped(
        address indexed user,
        address indexed assetIn,
        address indexed assetOut,
        uint256 amountIns,
        uint256 amountOuts,
        uint256 fees,
        uint256 timestamp
    );

    event Staked(
        address indexed user,
        address indexed asset,
        uint256 amount,
        uint256 stakeId
    );
    event UnStaked(
        address indexed user,
        address indexed asset,
        uint256 stakeId,
        uint256 fee,
        uint256 amount
    );

    constructor(
        address _owner,
        address _ytc,
        address _lcx,
        address _treasury,
        uint256 _platformFee,
        uint256 _unStakeFee
    ) Ownable(_owner) {
        YTC = (_ytc);
        LCX = (_lcx);
        treasury = (_treasury);
        platformFee = _platformFee;
        unStakeFee = _unStakeFee;
        activePriceFeed[address(YTC)] = PriceFeed.MANUAL;
        activePriceFeed[address(LCX)] = PriceFeed.MANUAL;
        manualPrice[address(YTC)] = 1e18;
        manualPrice[address(LCX)] = 0.5e18;
        stakesFeed[_ytc] = StakeFeed({
            min: 100e18,
            max: 1000e18,
            rate: 10e18,
            period: 365 days
        });
        stakesFeed[_lcx] = StakeFeed({
            min: 100e18,
            max: 1000e18,
            rate: 10e18,
            period: 365 days
        });
    }

    receive() external payable {}

    modifier onlyValidUser(address _user) {
        require(_user != address(0), "!ZERO");
        require(msg.sender == _user, "!USER");
        _;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unPause() external onlyOwner {
        _unpause();
    }

    function updateTokens(
        address _newAddress,
        TokenFeed feed
    ) external onlyOwner {
        require(_newAddress != address(0), "Invalid address!");
        if (feed == TokenFeed.YTC) YTC = _newAddress;
        else if (feed == TokenFeed.LCX) LCX = _newAddress;
        else if (feed == TokenFeed.USDT) USDT = _newAddress;
        else if (feed == TokenFeed.USDC) USDC = _newAddress;
        else if (feed == TokenFeed.WBNB) WBNB = _newAddress;
        else if (feed == TokenFeed.ROUTER) pancakeRouter = _newAddress;
        else if (feed == TokenFeed.TREASURY) treasury = payable(_newAddress);
        else revert("Invalid Feed!");
    }

    function setStakeData(
        address _token,
        uint256[4] memory _value
    ) external onlyOwner {
        require(_token != address(0), "Invalid address!");
        stakesFeed[_token] = StakeFeed({
            min: _value[0],
            max: _value[1],
            rate: _value[2],
            period: _value[3]
        });
    }

    function addManualLiqudity(
        address token,
        uint256 amount
    ) external payable onlyOwner {
        require(amount > 0, "Invalid Amount!");
        if (token == address(0)) {
            require(amount == msg.value, "Invalid amount!");
            return;
        }
        require(msg.value == 0, "Invalid data!");
        IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);
    }

    function removeLiqudity(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(to != address(0), "Invalid Address");
        require(amount > 0, "Invalid Amount");
        if (token == address(0))
            require(payable(to).send(amount), "BNB transfer failed!");
        else {
            require(
                IERC20(token).balanceOf(address(this)) >= amount,
                "Retrieve: Insufficient balance"
            );
            SafeERC20.safeTransfer(IERC20(token), to, amount);
        }
    }

    function setprice(address _token, uint256 _price) external onlyOwner {
        require(_token != address(0), "Invalid address!");
        require(_price > 0, "Invalid data!");
        manualPrice[_token] = _price;
    }

    function setPriceFeed(address _token, PriceFeed feed) external onlyOwner {
        require(
            feed == PriceFeed.MANUAL || feed == PriceFeed.DEX,
            "Invalid Feed!"
        );
        activePriceFeed[_token] = feed;
    }

    function setPlatformFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "Invalid Fee!");
        platformFee = _fee;
    }

    function setStakeFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "Invalid Fee!");
        unStakeFee = _fee;
    }

    function getPlatformFee(
        uint256 _amountIn
    ) external view returns (uint256 amountIn, uint256 feeAmount) {
        feeAmount = ((_amountIn * platformFee) / MAX_FEE);
        amountIn = (_amountIn - feeAmount);
    }

    function getPrice(address token) public view returns (uint256) {
        if (activePriceFeed[token] == PriceFeed.MANUAL) {
            uint256 price = manualPrice[token];
            require(price > 0, "Manual price not set");
            return price;
        }
        return 0;
    }

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
        (amountIn, fee) = internalSupportingTransactions(
            to,
            path[0],
            address(_router),
            amountIn
        );

        amounts = IPancakeRouter02(_router).swapExactTokensForTokens(
            amountIn,
            amountOutMin,
            path,
            to,
            deadline
        );
        emit YapitSwapped(
            to,
            path[0],
            path[path.length - 1],
            amountIn,
            amounts[amounts.length - 1],
            fee,
            block.timestamp
        );
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
        (amountInMax, fee) = internalSupportingTransactions(
            to,
            path[0],
            address(_router),
            amountInMax
        );
        amounts = IPancakeRouter02(_router).swapTokensForExactETH(
            amountOut,
            amountInMax,
            path,
            to,
            deadline
        );
        emit YapitSwapped(
            to,
            path[0],
            path[path.length - 1],
            amountInMax,
            amounts[amounts.length - 1],
            fee,
            block.timestamp
        );
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
        (amountIn, fee) = internalSupportingTransactions(
            to,
            path[0],
            address(_router),
            amountIn
        );
        amounts = IPancakeRouter02(_router).swapExactTokensForETH(
            amountIn,
            amountOutMin,
            path,
            to,
            deadline
        );
        emit YapitSwapped(
            to,
            path[0],
            path[path.length - 1],
            amountIn,
            amounts[amounts.length - 1],
            fee,
            block.timestamp
        );
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
        (amountInMax, fee) = internalSupportingTransactions(
            to,
            path[0],
            address(_router),
            amountInMax
        );
        amounts = IPancakeRouter02(_router).swapTokensForExactTokens(
            amountOut,
            amountInMax,
            path,
            to,
            deadline
        );
        emit YapitSwapped(
            to,
            path[0],
            path[path.length - 1],
            amountInMax,
            amounts[amounts.length - 1],
            fee,
            block.timestamp
        );
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
        amounts = IPancakeRouter02(_router).swapExactETHForTokens{
            value: amountIn
        }(amountOutMin, path, to, deadline);
        if (fee > 0) {
            require(
                address(this).balance >= fee,
                "yapit : Insufficient Liqudity!"
            );
            payable(treasury).transfer(fee);
        }
        emit YapitSwapped(
            to,
            path[0],
            path[path.length - 1],
            amountIn,
            amounts[amounts.length - 1],
            fee,
            block.timestamp
        );
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
        amounts = IPancakeRouter02(_router).swapETHForExactTokens{
            value: amountIn
        }(amountOut, path, to, deadline);
        if (fee > 0) {
            require(
                address(this).balance >= fee,
                "yapit : Insufficient Liqudity!"
            );
            payable(treasury).transfer(fee);
        }
        emit YapitSwapped(
            to,
            path[0],
            path[path.length - 1],
            amountIn,
            amounts[amounts.length - 1],
            fee,
            block.timestamp
        );
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
        (amountIn, fee) = internalSupportingTransactions(
            to,
            path[0],
            address(_router),
            amountIn
        );
        IPancakeRouter02(_router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn,
                amountOutMin,
                path,
                to,
                deadline
            );
        emit YapitSwapped(
            to,
            path[0],
            path[path.length - 1],
            amountIn,
            amountOutMin,
            fee,
            block.timestamp
        );
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
        IPancakeRouter02(_router)
            .swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: amountIn
        }(amountOutMin, path, to, deadline);
        if (fee > 0) {
            require(
                address(this).balance >= fee,
                "yapit : Insufficient Liqudity!"
            );
            payable(treasury).transfer(fee);
        }
        emit YapitSwapped(
            to,
            path[0],
            path[path.length - 1],
            amountIn,
            amountOutMin,
            fee,
            block.timestamp
        );
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
        (amountIn, fee) = internalSupportingTransactions(
            to,
            path[0],
            address(_router),
            amountIn
        );
        IPancakeRouter02(_router)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(
                amountIn,
                amountOutMin,
                path,
                to,
                deadline
            );
        emit YapitSwapped(
            to,
            path[0],
            path[path.length - 1],
            amountIn,
            amountOutMin,
            fee,
            block.timestamp
        );
    }

    function unStake(uint256 stakeId) external whenNotPaused nonReentrant {
        address user = _msgSender();
        userStake storage stake = stakerInfo[user][stakeId];
        require(stake.stakeAmount > 0, "Invalid User!");
        require(stake.lastClaim == 0, "Unstaked!");
        require(block.timestamp >= stake.endTime, "period!");
        uint256 fee;
        uint256 payOut;
        address lp = stake.stakeToken;
        if (unStakeFee > 0) {
            fee = (stake.rewardAmount * unStakeFee) / MAX_FEE;
            require(
                IERC20(lp).balanceOf(address(this)) >= (fee),
                "yapit : Insufficient Liqudity Fee!"
            );
            IERC20(lp).safeTransfer(treasury, fee);
        }
        payOut = (stake.stakeAmount + (stake.rewardAmount - fee));
        require(
            IERC20(lp).balanceOf(address(this)) >= (payOut),
            "yapit : Insufficient Liqudity!"
        );

        IERC20(lp).safeTransfer(user, payOut);
        stake.lastClaim = block.timestamp;
        emit UnStaked(user, lp, stakeId, fee, payOut);
    }

    function internalProcess(
        address _user,
        address _token,
        address _router,
        uint256 amount
    ) private returns (uint256 _amount, uint256 _fee) {
        IERC20(_token).safeTransferFrom(_user, address(this), amount);
        (_amount, _fee) = this.getPlatformFee(amount);
        IERC20(_token).safeIncreaseAllowance(_router, amount);
        if (_fee > 0) {
            require(
                IERC20(_token).balanceOf(address(this)) >= _fee,
                "yapit : Insufficient Liqudity!"
            );
            IERC20(_token).safeTransfer(treasury, _fee);
        }
        return (_amount, _fee);
    }

    function internalSupportingTransactions(
        address _user,
        address _token,
        address _router,
        uint256 _amount
    ) private returns (uint256 amount, uint256 _fee) {
        uint256 beforeBalance = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransferFrom(_user, address(this), _amount);
        uint256 afterBalance = IERC20(_token).balanceOf(address(this));
        _amount = afterBalance - beforeBalance;
        (_amount, _fee) = this.getPlatformFee(_amount);
        if (_fee > 0) {
            require(
                IERC20(_token).balanceOf(address(this)) >= _fee,
                "yapit : Insufficient Liqudity!"
            );
            IERC20(_token).safeTransfer(treasury, _fee);
        }
        IERC20(_token).safeIncreaseAllowance(_router, _amount);
        return (_amount, _fee);
    }

    function swap(
        address[] memory _path,
        uint256 _amountIn,
        address _to
    ) external payable whenNotPaused nonReentrant onlyValidUser(_to) {
        require(_amountIn > 0, "Invalid amount!");
        require(_path[0] != _path[_path.length - 1], "Identical pair!");
        require(
            (_path.length == 2 && _path[0] != address(0)) &&
                _path[1] != address(0),
            "Invalid path!"
        );
        if (_path[0] != WBNB) require(msg.value == 0, "Invalid value!");
        uint256 fee;
        (_amountIn, fee) = this.getPlatformFee(_amountIn);

        if ((_path[0]) != address(WBNB)) {
            IERC20(_path[0]).safeTransferFrom(_to, treasury, fee);
            IERC20(_path[0]).safeTransferFrom(_to, address(this), _amountIn);
        } else {
            require(msg.value == _amountIn + fee);
            payable(treasury).transfer(fee);
        }

        uint256 amountOut;

        if (
            PriceFeed.MANUAL == activePriceFeed[_path[0]] ||
            PriceFeed.MANUAL == activePriceFeed[_path[_path.length - 1]]
        ) {
            amountOut = this.calcOutAmount(
                _path[0],
                _path[_path.length - 1],
                _amountIn
            );
            if (address(_path[_path.length - 1]) == address(WBNB)) {
                payable(_to).transfer(amountOut);
            } else {
                if (
                    address(_path[_path.length - 1]) == address(YTC) ||
                    address(_path[_path.length - 1]) == address(LCX)
                ) {
                    _stake(_msgSender(), _path[_path.length - 1], amountOut);
                } else {
                    IERC20(_path[_path.length - 1]).safeTransfer(
                        _to,
                        amountOut
                    );
                }
            }
        } else {
            revert("priceFeed mismatch!");
        }
        emit YapitSwapped(
            _to,
            _path[0],
            _path[_path.length - 1],
            _amountIn,
            amountOut,
            fee,
            block.timestamp
        );
    }

    function calcOutAmount(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn
    ) external view returns (uint256 amountOut) {
        if (
            activePriceFeed[_tokenIn] == PriceFeed.MANUAL &&
            address(_tokenOut) != address(WBNB)
        ) {
            amountOut = ((_amountIn * PRECISION) / getPrice(_tokenIn));
        } else if (
            address(_tokenIn) == address(USDT) ||
            address(_tokenIn) == address(USDC)
        ) {
            amountOut = ((_amountIn * getPrice(_tokenOut)) / PRECISION);
        } else {
            if (_tokenIn == WBNB) {
                address[] memory path = new address[](2);
                path[0] = WBNB;
                path[1] = address(USDT);
                amountOut = IPancakeRouter02(pancakeRouter).getAmountsOut(
                    _amountIn,
                    path
                )[path.length - 1];
                amountOut = ((_amountIn * getPrice(_tokenOut)) / PRECISION);
            } else {
                uint256 usdValue = ((_amountIn * PRECISION) /
                    getPrice(_tokenIn));
                address[] memory path = new address[](2);
                path[0] = address(USDT);
                path[1] = WBNB;
                amountOut = IPancakeRouter02(pancakeRouter).getAmountsOut(
                    usdValue,
                    path
                )[path.length - 1];
            }
        }
    }

    function getData(address _token) internal view returns (StakeFeed memory) {
        return stakesFeed[_token];
    }

    function _stake(address user, address _token, uint256 _amount) internal {
        StakeFeed memory data = getData(_token);
        require(data.max >= _amount && _amount >= data.min, "MIN_MAX!");
        uint256 sid = (++stakeIds[user]);
        uint256 ts = block.timestamp;
        userStake memory stake = userStake({
            stakeToken: _token,
            stakeAmount: _amount,
            stakeTime: ts,
            endTime: (ts + data.period),
            rewardAmount: ((_amount * data.rate) / MAX_FEE),
            lastClaim: 0
        });
        stakerInfo[user][sid] = stake;
        emit Staked(user, _token, _amount, sid);
    }
}