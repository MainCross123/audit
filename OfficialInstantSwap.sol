// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
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

contract OfficialInstantSwap is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  IUniswapV2Router02 public v2Router;
  IV3SwapRouter public v3Router;

  address public USDC;
  address public weth;
  address public executor;
  error FailedCall();
  modifier onlyExecutor() {
    require(msg.sender == executor, "not executor");
    _;
  }


  //////////================= Events ====================================================
  event SwapFromUSDC(
    address indexed receiver,
    address indexed token,
    uint256 amountIn,
    uint256 time
  );

  event ExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);
  constructor(
    address _v3Router,
    address _v2Router,
    address _executor,
    address _usdc,
    address _weth
  ) Ownable(msg.sender) {
    v3Router = IV3SwapRouter(_v3Router);
    v2Router = IUniswapV2Router02(_v2Router);
    executor= _executor;
    USDC = _usdc;
    weth= _weth;
  }

  function swapFromUSDC(
    address _outputToken,
    uint256 _amountIn,
    uint256 _minAmountOut,
    uint256 _minAmountOutV2Swap,
    bool _useV2,
    address[] memory _pathV2,
    bytes memory _pathV3,
    address to,
    bool unwrapETH
  ) public  nonReentrant onlyExecutor {
    // USDC -> Token
    if(_outputToken == USDC) {
      IERC20(USDC).transfer(to, _amountIn);
      emit SwapFromUSDC(to, USDC, _amountIn, block.timestamp);
      return;
    }

    // 1. Swap USDC to ETH (and/or final token) on v3
    IERC20(USDC).approve(address(v3Router), _amountIn);
    IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams(
      _pathV3, _useV2 || unwrapETH? address(this) : to, _amountIn, _minAmountOut
    );

    uint256 wethOrFinalTokenOut = v3Router.exactInput(params);

    if(_useV2) {
      IERC20(weth).approve(address(v2Router), wethOrFinalTokenOut);
      v2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
        wethOrFinalTokenOut,
        _minAmountOutV2Swap,
        _pathV2,
        unwrapETH? address(this) : to,
        block.timestamp + 1 hours
      );
    }

    if(unwrapETH) {
      uint256 wethBalance = IERC20(weth).balanceOf(address(this));
      IWETH(weth).withdraw(wethBalance);
      // payable(receiverData.userReceiver).transfer(address(this).balance);
      (bool success, ) = to.call{value: address(this).balance}("");
      if(!success) {
          revert FailedCall();
      }
    }
    emit SwapFromUSDC(to, _outputToken, _amountIn, block.timestamp);
  }

  function setExecutor(address _newExecutor) external onlyOwner {
    emit ExecutorUpdated(executor, _newExecutor);
    executor = _newExecutor;
  }

  function recoverStuckTokens(address _token) external onlyOwner {
    uint256 amount = IERC20(_token).balanceOf(address(this));
    IERC20(_token).transfer(owner(), amount);
  }


  receive() external payable {}

  fallback() external payable {}
}