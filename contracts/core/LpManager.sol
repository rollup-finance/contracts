// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "./interfaces/IVault.sol";
import "./interfaces/ILpManager.sol";
import "./interfaces/IShortsTracker.sol";
import "../tokens/interfaces/IUSDR.sol";
import "../tokens/interfaces/IMintable.sol";
import "../access/Governable.sol";


contract LpManager is ReentrancyGuard, Governable, ILpManager {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant USDR_DECIMALS = 18;
    uint256 public constant LP_PRECISION = 10 ** 18;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    IVault public override vault;
    IShortsTracker public shortsTracker;
    address public override usdr;
    address public override lp;

    uint256 public override cooldownDuration;
    mapping (address => uint256) public override lastAddedAt;

    uint256 public aumAddition;
    uint256 public aumDeduction;

    bool public inPrivateMode;
    uint256 public shortsTrackerAveragePriceWeight;
    mapping (address => bool) public isHandler;

    event AddLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 aumInUsdr,
        uint256 lpSupply,
        uint256 usdrAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        address token,
        uint256 lpAmount,
        uint256 aumInUsdr,
        uint256 lpSupply,
        uint256 usdrAmount,
        uint256 amountOut
    );

    constructor(address _vault, address _usdr, address _lp, address _shortsTracker, uint256 _cooldownDuration) {
        gov = msg.sender;
        vault = IVault(_vault);
        usdr = _usdr;
        lp = _lp;
        shortsTracker = IShortsTracker(_shortsTracker);
        cooldownDuration = _cooldownDuration;
    }

    function setInPrivateMode(bool _inPrivateMode) external onlyGov {
        inPrivateMode = _inPrivateMode;
    }

    function setShortsTracker(IShortsTracker _shortsTracker) external onlyGov {
        shortsTracker = _shortsTracker;
    }

    function setShortsTrackerAveragePriceWeight(uint256 _shortsTrackerAveragePriceWeight) external override onlyGov {
        require(shortsTrackerAveragePriceWeight <= BASIS_POINTS_DIVISOR, "invalid weight");
        shortsTrackerAveragePriceWeight = _shortsTrackerAveragePriceWeight;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setCooldownDuration(uint256 _cooldownDuration) external override onlyGov {
        require(_cooldownDuration <= MAX_COOLDOWN_DURATION, "invalid _cooldownDuration");
        cooldownDuration = _cooldownDuration;
    }

    function setAumAdjustment(uint256 _aumAddition, uint256 _aumDeduction) external onlyGov {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
    }

    function addLiquidity(address _token, uint256 _amount, uint256 _minUsdr, uint256 _minLp) external override nonReentrant returns (uint256) {
        if (inPrivateMode) { revert("action not enabled"); }
        return _addLiquidity(msg.sender, msg.sender, _token, _amount, _minUsdr, _minLp);
    }

    function addLiquidityForAccount(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdr, uint256 _minLp) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _addLiquidity(_fundingAccount, _account, _token, _amount, _minUsdr, _minLp);
    }

    function removeLiquidity(address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        if (inPrivateMode) { revert("action not enabled"); }
        return _removeLiquidity(msg.sender, _tokenOut, _lpAmount, _minOut, _receiver);
    }

    function removeLiquidityForAccount(address _account, address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _removeLiquidity(_account, _tokenOut, _lpAmount, _minOut, _receiver);
    }

    function getPrice(bool _maximise) external view returns (uint256) {
        uint256 aum = getAum(_maximise);
        uint256 supply = IERC20(lp).totalSupply();
        return aum.mul(LP_PRECISION).div(supply);
    }

    function getAums() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = getAum(true);
        amounts[1] = getAum(false);
        return amounts;
    }

    function getAumInUsdr(bool maximise) public override view returns (uint256) {
        uint256 aum = getAum(maximise);
        return aum.mul(10 ** USDR_DECIMALS).div(PRICE_PRECISION);
    }

    function getAum(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum = aumAddition;
        uint256 shortProfits = 0;
        IVault _vault = vault;

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                continue;
            }

            uint256 price = maximise ? _vault.getMaxPrice(token) : _vault.getMinPrice(token);
            uint256 poolAmount = _vault.poolAmounts(token);
            uint256 decimals = _vault.tokenDecimals(token);

            if (_vault.stableTokens(token)) {
                aum = aum.add(poolAmount.mul(price).div(10 ** decimals));
            } else {
                // add global short profit / loss
                uint256 size = _vault.globalShortSizes(token);

                if (size > 0) {
                    (uint256 delta, bool hasProfit) = getGlobalShortDelta(token, price, size);
                    if (!hasProfit) {
                        // add losses from shorts
                        aum = aum.add(delta);
                    } else {
                        shortProfits = shortProfits.add(delta);
                    }
                }

                aum = aum.add(_vault.guaranteedUsd(token));

                uint256 reservedAmount = _vault.reservedAmounts(token);
                aum = aum.add(poolAmount.sub(reservedAmount).mul(price).div(10 ** decimals));
            }
        }

        aum = shortProfits > aum ? 0 : aum.sub(shortProfits);
        return aumDeduction > aum ? 0 : aum.sub(aumDeduction);
    }

    function getGlobalShortDelta(address _token, uint256 _price, uint256 _size) public view returns (uint256, bool) {
        uint256 averagePrice = getGlobalShortAveragePrice(_token);
        uint256 priceDelta = averagePrice > _price ? averagePrice.sub(_price) : _price.sub(averagePrice);
        uint256 delta = _size.mul(priceDelta).div(averagePrice);
        return (delta, averagePrice > _price);
    }

    function getGlobalShortAveragePrice(address _token) public view returns (uint256) {
        IShortsTracker _shortsTracker = shortsTracker;
        if (address(_shortsTracker) == address(0) || !_shortsTracker.isGlobalShortDataReady()) {
            return vault.globalShortAveragePrices(_token);
        }

        uint256 _shortsTrackerAveragePriceWeight = shortsTrackerAveragePriceWeight;
        if (_shortsTrackerAveragePriceWeight == 0) {
            return vault.globalShortAveragePrices(_token);
        } else if (_shortsTrackerAveragePriceWeight == BASIS_POINTS_DIVISOR) {
            return _shortsTracker.globalShortAveragePrices(_token);
        }

        uint256 vaultAveragePrice = vault.globalShortAveragePrices(_token);
        uint256 shortsTrackerAveragePrice = _shortsTracker.globalShortAveragePrices(_token);

        return vaultAveragePrice.mul(BASIS_POINTS_DIVISOR.sub(_shortsTrackerAveragePriceWeight))
            .add(shortsTrackerAveragePrice.mul(_shortsTrackerAveragePriceWeight))
            .div(BASIS_POINTS_DIVISOR);
    }

    function _addLiquidity(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdr, uint256 _minLp) private returns (uint256) {
        require(_amount > 0, "invalid _amount");

        // calculate aum before buyUSDR
        uint256 aumInUsdr = getAumInUsdr(true);
        uint256 lpSupply = IERC20(lp).totalSupply();

        IERC20(_token).safeTransferFrom(_fundingAccount, address(vault), _amount);
        uint256 usdrAmount = vault.buyUSDR(_token, address(this));
        require(usdrAmount >= _minUsdr, "insufficient USDR output");

        uint256 mintAmount = aumInUsdr == 0 ? usdrAmount : usdrAmount.mul(lpSupply).div(aumInUsdr);
        require(mintAmount >= _minLp, "insufficient LP output");

        IMintable(lp).mint(_account, mintAmount);

        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(_account, _token, _amount, aumInUsdr, lpSupply, usdrAmount, mintAmount);

        return mintAmount;
    }

    function _removeLiquidity(address _account, address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _receiver) private returns (uint256) {
        require(_lpAmount > 0, "invalid _lpAmount");
        require(lastAddedAt[_account].add(cooldownDuration) <= block.timestamp, "cooldown duration not yet passed");

        // calculate aum before sellUSDR
        uint256 aumInUsdr = getAumInUsdr(false);
        uint256 lpSupply = IERC20(lp).totalSupply();

        uint256 usdrAmount = _lpAmount.mul(aumInUsdr).div(lpSupply);
        uint256 usdrBalance = IERC20(usdr).balanceOf(address(this));
        if (usdrAmount > usdrBalance) {
            IUSDR(usdr).mint(address(this), usdrAmount.sub(usdrBalance));
        }

        IMintable(lp).burn(_account, _lpAmount);

        IERC20(usdr).transfer(address(vault), usdrAmount);
        uint256 amountOut = vault.sellUSDR(_tokenOut, _receiver);
        require(amountOut >= _minOut, "insufficient output");

        emit RemoveLiquidity(_account, _tokenOut, _lpAmount, aumInUsdr, lpSupply, usdrAmount, amountOut);

        return amountOut;
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "!handler");
    }
}
