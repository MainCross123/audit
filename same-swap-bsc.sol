// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import '@openzeppelin/contracts/access/Ownable2Step.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/utils/ReentrancyGuard.sol';
import './libs/BytesLib.sol';

interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IV2SwapRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint amount) external;
}

contract SameChainSwapBSC is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    mapping(address => bool) public feeTokens;
    uint256 public platformFee; // Fee must be by 1000, so if you want 5% this will be 5000
    address public feeReceiver;
    uint256 public constant feeBps = 1000; // 1000 is 1% so we can have many decimals

    IV2SwapRouter public v2Router;
    IV3SwapRouter public v3Router;
    address public wethToken;

    error FailedCall(); // Used when transfer function is failed.
    //////////================= Events ====================================================
    event SwapExecuted(address indexed tokenIn, address indexed tokenOut, uint amountIn, uint amountOut);
    event FeeReceiverSet(address indexed _oldReceiver, address indexed _newReceiver);
    event Fee(address indexed user, uint256 amount, address indexed token);

    constructor(
        uint256 _fee,
        address _feeReceiver,
        address _v3Router,
        address _v2Router,
        address _weth
    ) Ownable(msg.sender) {
        platformFee = _fee;
        feeReceiver = _feeReceiver;
        v3Router = IV3SwapRouter(_v3Router);
        v2Router = IV2SwapRouter(_v2Router);
        wethToken = _weth;
    }
    uint256 public constant MAX_PLATFORM_FEE = 2000; // 20% in basis points
    uint256 public threshold = 0.01 * 10 ** 18; // 20% in basis points
    function changeFeeData(uint256 _fee, address _feeReceiver, uint256 _threshold) external onlyOwner {
        require(_fee <= MAX_PLATFORM_FEE, 'Platform fee exceeds the maximum limit');
        address oldReceiver = feeReceiver;
        platformFee = _fee;
        feeReceiver = _feeReceiver;
        threshold = _threshold;
        emit FeeReceiverSet(oldReceiver, _feeReceiver);
    }

    function swapOnce(
        address _tokenA,
        address _tokenB,
        bool _unwrappETH,
        uint256 _amountIn,
        uint256 _minAmountOutV2,
        uint256 _minAmountOutV3,
        uint8 _buyOneTwoOrThree, // 1 means buy only v2, 2 means buy v3 only, 3 means buy first v2 then v3, 4 means buy first v3 then v2
        address[] memory _pathV2,
        bytes memory _pathV3,
        bool isWethIn
    ) public payable nonReentrant {
        // ETH -> Token
        if (!isWethIn && _tokenA == wethToken) {
            require(msg.value > 0, 'invalid msg.value');
            IWETH(wethToken).deposit{value: msg.value}();
        } else {
            require(msg.value == 0, 'invalid msg.value');
            uint256 beforeTransfer = IERC20(_tokenA).balanceOf(address(this));
            IERC20(_tokenA).safeTransferFrom(msg.sender, address(this), _amountIn);
            uint256 afterTransfer = IERC20(_tokenA).balanceOf(address(this));
            _amountIn = afterTransfer - beforeTransfer;
        }

        uint256 amountIn = (msg.value > 0 ? msg.value : _amountIn);
        uint256 output;
        if (_buyOneTwoOrThree == 1) {
            uint256 feeAmount = (amountIn * platformFee) / (feeBps * 100);
            if (_pathV2[0] != wethToken) {
                // WETH => Token
                address[] memory path = new address[](2);
                path[0] = _pathV2[0];
                path[1] = wethToken;
                v2Swap(path, feeAmount, 0);
            }
            output = v2Swap(_pathV2, amountIn - feeAmount, _minAmountOutV2);
        } else if (_buyOneTwoOrThree == 2) {
            uint256 feeAmount = (amountIn * platformFee) / (feeBps * 100);
            if (_pathV3.toAddress(0) == wethToken) {
                // WETH => output Token
                output = v3Swap(_tokenA, _pathV3, amountIn - feeAmount, _minAmountOutV3);
            } else if (_pathV3.toAddress(23) == wethToken && _tokenB == wethToken) {
                // Token => WETH
                output = v3Swap(_tokenA, _pathV3, amountIn, _minAmountOutV3);
                feeAmount = (output * platformFee) / (feeBps * 100);
                output = output - feeAmount;
            } else {
                // Token => WETH (stable coins) => Token
                v3Swap(_tokenA, _pathV3.slice(0, 43), feeAmount, 0);
                output = v3Swap(_tokenA, _pathV3, amountIn - feeAmount, _minAmountOutV3);
            }
        } else if (_buyOneTwoOrThree == 3) {
            output = v2Swap(_pathV2, amountIn, _minAmountOutV2);
            uint256 feeAmount = (output * platformFee) / (feeBps * 100);
            output = v3Swap(_pathV2[_pathV2.length - 1], _pathV3, output - feeAmount, _minAmountOutV3);
        } else if (_buyOneTwoOrThree == 4) {
            output = v3Swap(_tokenA, _pathV3, amountIn, _minAmountOutV3);
            uint256 feeAmount = (output * platformFee) / (feeBps * 100);
            output = v2Swap(_pathV2, output - feeAmount, _minAmountOutV2);
        }

        if (_unwrappETH) {
            IWETH(wethToken).withdraw(output);
            // payable(msg.sender).transfer(output);
            (bool success, ) = msg.sender.call{value: output}('');
            if (!success) {
                revert FailedCall();
            }
        } else {
            IERC20(_tokenB).safeTransfer(msg.sender, output);
        }
        if (IWETH(wethToken).balanceOf(address(this)) >= threshold) {
            IWETH(wethToken).withdraw(IWETH(wethToken).balanceOf(address(this)));
            payable(feeReceiver).transfer(address(this).balance);
        }
        emit SwapExecuted(_tokenA, _tokenB, _amountIn, output);
    }

    function checkAndApproveAll(address _token, address _target, uint256 _amountToCheck) internal {
        if (IERC20(_token).allowance(address(this), _target) < _amountToCheck) {
            IERC20(_token).forceApprove(_target, 0);
            IERC20(_token).forceApprove(_target, ~uint256(0));
        }
    }

    function v2Swap(
        address[] memory _path,
        uint256 _amountIn,
        uint256 _minAmountOut // Slippage in base of 1000 meaning 10 is 1% and 1 is 0.1% where 1000 is 1
    ) internal returns (uint256) {
        address tokenOut = _path[_path.length - 1];
        checkAndApproveAll(_path[0], address(v2Router), _amountIn);
        uint256 initial = IERC20(tokenOut).balanceOf(address(this));
        v2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            _minAmountOut,
            _path,
            address(this),
            block.timestamp * 5 minutes
        );
        uint256 finalAmount = IERC20(tokenOut).balanceOf(address(this));
        return finalAmount - initial;
    }

    function v3Swap(
        address _tokenIn,
        bytes memory _path,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) internal returns (uint256 amountOutput) {
        checkAndApproveAll(_tokenIn, address(v3Router), _amountIn);
        IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams(
            _path,
            address(this),
            block.timestamp * 5 minutes,
            _amountIn,
            _minAmountOut
        );
        amountOutput = v3Router.exactInput(params);
    }

    function recoverStuckETH(address payable _beneficiary) public onlyOwner {
        _beneficiary.transfer(address(this).balance);
    }

    function recoverStuckTokens(address _token) external onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(owner(), amount);
    }

    receive() external payable {}

    fallback() external payable {}
}
