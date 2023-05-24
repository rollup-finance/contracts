// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IRewardTracker.sol";
import "./interfaces/IRewardRouterV1.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "../core/interfaces/ILpManager.sol";
import "../access/Governable.sol";

contract RewardRouterV1 is IRewardRouterV1, ReentrancyGuard, Governable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public weth;

    address public lp; // COIN Liquidity Provider token

    address public override feeLpTracker;

    address public lpManager;

    mapping (address => address) public pendingReceivers;

    event StakeLp(address account, uint256 amount);
    event UnstakeLp(address account, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    function initialize(
        address _weth,
        address _lp,
        address _feeLpTracker,
        address _lpManager
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;

        weth = _weth;

        lp = _lp;

        feeLpTracker = _feeLpTracker;

        lpManager = _lpManager;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function mintAndStakeLp(address _token, uint256 _amount, uint256 _minUsdr, uint256 _minLp) external nonReentrant returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");

        address account = msg.sender;
        uint256 lpAmount = ILpManager(lpManager).addLiquidityForAccount(account, account, _token, _amount, _minUsdr, _minLp);
        IRewardTracker(feeLpTracker).stakeForAccount(account, account, lp, lpAmount);

        emit StakeLp(account, lpAmount);

        return lpAmount;
    }

    function mintAndStakeLpETH(uint256 _minUsdr, uint256 _minLp) external payable nonReentrant returns (uint256) {
        require(msg.value > 0, "RewardRouter: invalid msg.value");

        IWETH(weth).deposit{value: msg.value}();
        IERC20(weth).approve(lpManager, msg.value);

        address account = msg.sender;
        uint256 lpAmount = ILpManager(lpManager).addLiquidityForAccount(address(this), account, weth, msg.value, _minUsdr, _minLp);

        IRewardTracker(feeLpTracker).stakeForAccount(account, account, lp, lpAmount);

        emit StakeLp(account, lpAmount);

        return lpAmount;
    }

    function unstakeAndRedeemLp(address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _receiver) external nonReentrant returns (uint256) {
        require(_lpAmount > 0, "RewardRouter: invalid _lpAmount");

        address account = msg.sender;
        IRewardTracker(feeLpTracker).unstakeForAccount(account, lp, _lpAmount, account);
        uint256 amountOut = ILpManager(lpManager).removeLiquidityForAccount(account, _tokenOut, _lpAmount, _minOut, _receiver);

        emit UnstakeLp(account, _lpAmount);

        return amountOut;
    }

    function unstakeAndRedeemLpETH(uint256 _lpAmount, uint256 _minOut, address payable _receiver) external nonReentrant returns (uint256) {
        require(_lpAmount > 0, "RewardRouter: invalid _lpAmount");

        address account = msg.sender;
        IRewardTracker(feeLpTracker).unstakeForAccount(account, lp, _lpAmount, account);
        uint256 amountOut = ILpManager(lpManager).removeLiquidityForAccount(account, weth, _lpAmount, _minOut, address(this));

        IWETH(weth).withdraw(amountOut);

        _receiver.sendValue(amountOut);

        emit UnstakeLp(account, _lpAmount);

        return amountOut;
    }

    function claim() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeLpTracker).claimForAccount(account, account);
    }

    function claimFees() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeLpTracker).claimForAccount(account, account);
    }

    function handleRewards(
        bool _shouldConvertWethToEth
    ) external nonReentrant {
        address account = msg.sender;

        if (_shouldConvertWethToEth) {
            uint256 wethAmount = IRewardTracker(feeLpTracker).claimForAccount(account, address(this));
            IWETH(weth).withdraw(wethAmount);

            payable(account).sendValue(wethAmount);
        } else {
            IRewardTracker(feeLpTracker).claimForAccount(account, account);
        }
    }

    function signalTransfer(address _receiver) external nonReentrant {
        _validateReceiver(_receiver);
        pendingReceivers[msg.sender] = _receiver;
    }

    function acceptTransfer(address _sender) external nonReentrant {
        address receiver = msg.sender;
        require(pendingReceivers[_sender] == receiver, "RewardRouter: transfer not signalled");
        delete pendingReceivers[_sender];

        _validateReceiver(receiver);

        uint256 lpAmount = IRewardTracker(feeLpTracker).depositBalances(_sender, lp);
        if (lpAmount > 0) {
            IRewardTracker(feeLpTracker).unstakeForAccount(_sender, lp, lpAmount, _sender);

            IRewardTracker(feeLpTracker).stakeForAccount(_sender, receiver, lp, lpAmount);
        }
    }

    function _validateReceiver(address _receiver) private view {
        require(IRewardTracker(feeLpTracker).averageStakedAmounts(_receiver) == 0, "RewardRouter: feeLpTracker.averageStakedAmounts > 0");
        require(IRewardTracker(feeLpTracker).cumulativeRewards(_receiver) == 0, "RewardRouter: feeLpTracker.cumulativeRewards > 0");
    }
}
