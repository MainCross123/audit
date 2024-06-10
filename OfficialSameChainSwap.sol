// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IV3SwapRouter {
  struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
  }
  function exactInputSingle(
    ExactInputSingleParams calldata params
  ) external payable returns (uint256 amountOut);

  struct ExactInputParams {
    bytes path;
    address recipient;
    uint256 amountIn;
    uint256 amountOutMinimum;
  }
  function exactInput(
    ExactInputParams calldata params
  ) external payable returns (uint256 amountOut);

  struct ExactOutputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountOut;
    uint256 amountInMaximum;
    uint160 sqrtPriceLimitX96;
  }
  function exactOutputSingle(
    ExactOutputSingleParams calldata params
  ) external payable returns (uint256 amountIn);

  struct ExactOutputParams {
    bytes path;
    address recipient;
    uint256 amountOut;
    uint256 amountInMaximum;
  }
  function exactOutput(
    ExactOutputParams calldata params
  ) external payable returns (uint256 amountIn);

  function uniswapV3SwapCallback(
    int256 amount0Delta,
    int256 amount1Delta,
    bytes calldata data
  ) external;

  function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to
  ) external payable returns (uint256 amountOut);
  function swapTokensForExactTokens(
    uint256 amountOut,
    uint256 amountInMax,
    address[] calldata path,
    address to
  ) external payable returns (uint256 amountIn);

  function WETH9() external view returns (address);
}

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

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

    function quote(uint amountA, uint reserveA, uint reserveB) external pure returns (uint amountB);
    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) external pure returns (uint amountOut);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IWETH is IERC20 {
    function deposit() external payable;

    function withdraw(uint amount) external;
}

contract OfficialSameChainSwap is Ownable2Step, ReentrancyGuard {
  using SafeERC20 for IERC20;

  mapping(address => bool) public feeTokens;
  uint256 public platformFee; // Fee must be by 1000, so if you want 5% this will be 5000
  address public feeReceiver;
  uint256 public constant feeBps = 1000; // 1000 is 1% so we can have many decimals

  IUniswapV2Router02 public v2Router;
  IV3SwapRouter public v3Router;
  address public wethToken;
  error FailedCall(); // Used when transfer function is failed.
  //////////================= Events ====================================================
  event SwapExecuted(
    address indexed tokenIn,
    address indexed tokenOut,
    uint amountIn,
    uint amountOut
  );
  event FeeReceiverSet(
    address indexed _oldReceiver,
    address indexed _newReceiver
  );
  event Fee(
    address indexed user, 
    uint256 amount, 
    address indexed token
  );

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
    v2Router = IUniswapV2Router02(_v2Router);
    wethToken = _weth;
  }

  uint256 public constant MAX_PLATFORM_FEE = 2000; // 20% in basis points
  function changeFeeData(uint256 _fee, address _feeReceiver) external onlyOwner {
    require(_fee <= MAX_PLATFORM_FEE, "Platform fee exceeds the maximum limit");
    address oldReceiver = feeReceiver;
    platformFee = _fee;
    feeReceiver = _feeReceiver;
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
      require(msg.value > 0, "invalid msg.value");
      IWETH(wethToken).deposit{value: msg.value}();
    } else {
      require(msg.value == 0, "invalid msg.value");
      uint256 beforeTransfer = IERC20(_tokenA).balanceOf(address(this));
      IERC20(_tokenA).safeTransferFrom(msg.sender, address(this), _amountIn);
      uint256 afterTransfer = IERC20(_tokenA).balanceOf(address(this));
      _amountIn = afterTransfer - beforeTransfer;
    }
    address feeToken = identifyFeeToken(_tokenA, _tokenB);

    uint256 amountIn = (msg.value > 0 ? msg.value : _amountIn);

    uint256 amountToSwap = amountIn;
    if (feeToken == _tokenA || feeToken == address(0)) {
      amountToSwap = deductFees(amountIn, _tokenA);
    }

    uint256 output;
    if (_buyOneTwoOrThree == 1) {
      output = v2Swap(_pathV2, amountToSwap, _minAmountOutV2);
    } else if (_buyOneTwoOrThree == 2) {
      output = v3Swap(_tokenA, _pathV3, amountToSwap, _minAmountOutV3);
    } else if (_buyOneTwoOrThree == 3) {
      output = v2Swap(_pathV2, amountToSwap, _minAmountOutV2);
      output = v3Swap(_pathV2[_pathV2.length - 1], _pathV3, output, _minAmountOutV3);
    } else if (_buyOneTwoOrThree == 4) {
      output = v3Swap(_tokenA, _pathV3, amountToSwap, _minAmountOutV3);
      output = v2Swap(_pathV2, output, _minAmountOutV2);
    }

    if (feeToken == _tokenB) {
      output = deductFees(output, _tokenB);
    }


    if (_unwrappETH && _tokenB == wethToken) {
      IWETH(wethToken).withdraw(output);
      // payable(msg.sender).transfer(output);
      (bool success, ) = msg.sender.call{value: output}("");
      if(!success) {
        revert FailedCall();
      }
    } else {
      IERC20(_tokenB).safeTransfer(msg.sender, output);
    }

    emit SwapExecuted(_tokenA, _tokenB, _amountIn, output);
  }

  function deductFees(uint _amount, address _token) internal returns(uint amountToSwap) {
    uint feeAmount = _amount * platformFee / (feeBps * 100);
    amountToSwap = _amount - feeAmount;
    IERC20(_token).safeTransfer(feeReceiver, feeAmount);
    emit Fee(msg.sender, feeAmount, _token);
  }
  

  function identifyFeeToken(address _tokenA, address _tokenB) internal view returns (address) {
    if (feeTokens[_tokenA]) {
      return _tokenA;
    } else if (feeTokens[_tokenB]) {
      return _tokenB;
    }
    return address(0);
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
        block.timestamp + 1 hours
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
      _path, address(this), _amountIn, _minAmountOut
    );
    amountOutput = v3Router.exactInput( params );
  }

  function recoverStuckETH(address payable _beneficiary) public onlyOwner {
    // _beneficiary.transfer(address(this).balance);
    (bool success, ) = _beneficiary.call{value: address(this).balance}("");
    if(!success) {
      revert FailedCall();
    }
  }

  function recoverStuckTokens(address _token) external onlyOwner {
    uint256 amount = IERC20(_token).balanceOf(address(this));
    IERC20(_token).safeTransfer(owner(), amount);
  }

  function addFeeToken(address _token) external onlyOwner {
    require(_token != address(0), "Invalid token address");
    feeTokens[_token] = true;
  }

  function removeFeeToken(address _token) external onlyOwner {
    require(_token != address(0), "Invalid token address");
    feeTokens[_token] = false;
  }


  receive() external payable {}

  fallback() external payable {}
}
