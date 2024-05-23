// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
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

contract OfficialInstantSwap is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  IUniswapV2Router02 public v2Router;
  IV3SwapRouter public v3Router;

  address public USDC;
  address public weth;
  address public executor;

  modifier onlyExecutor() {
    require(msg.sender == executor, "not executor");
    _;
  }


  //////////================= Events ====================================================
  event SwapFromUSDC(
    address indexed receiver,
    address indexed token,
    uint256 amountIn,
    uint256 amountOut,
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
    bool _useV2,
    address[] memory _pathV2,
    bytes memory _pathV3,
    address to,
    bool unwrapETH
  ) public  nonReentrant onlyExecutor {
    // USDC -> Token
    uint256 outputAmount;
    if(_useV2) {
      outputAmount = v2Swap(_pathV2, _amountIn, _minAmountOut, to, unwrapETH);
    } else {
      outputAmount = v3Swap(USDC, _pathV3, _amountIn, _minAmountOut, to, unwrapETH);
    }
    emit SwapFromUSDC(to, _outputToken, _amountIn, outputAmount, block.timestamp);
  }

  function directSendUSDC(address to, uint256 amount) external onlyExecutor {
    require(to != address(0), "can not send address(0)");
    IERC20(USDC).transfer(to, amount);
    emit SwapFromUSDC(to, USDC, amount,amount, block.timestamp);
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
    uint256 _minAmountOut, // Slippage in base of 1000 meaning 10 is 1% and 1 is 0.1% where 1000 is 1
    address to,
    bool unwrapETH
  ) internal returns (uint256) {
    address tokenOut = _path[_path.length - 1];
    checkAndApproveAll(_path[0], address(v2Router), _amountIn);
    uint256 initial = IERC20(tokenOut).balanceOf(to);
    v2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
        _amountIn,
        _minAmountOut,
        _path,
        unwrapETH ? address(this) : to,
        block.timestamp + 10 minutes
    );
    uint256 finalAmount = IERC20(tokenOut).balanceOf(to);
    if (unwrapETH) { // Get ETH at the end
        uint256 wethBalance = IERC20(weth).balanceOf(address(this));
        IWETH(weth).withdraw(wethBalance);
        payable(to).transfer(address(this).balance);
    }
    return finalAmount - initial;
  }

  function v3Swap(
    address _tokenIn,
    bytes memory _path,
    uint256 _amountIn,
    uint256 _minAmountOut,
    address to,
    bool unwrapETH
  ) internal returns (uint256 amountOutput) {
    checkAndApproveAll(_tokenIn, address(v3Router), _amountIn);
    IV3SwapRouter.ExactInputParams memory params = IV3SwapRouter.ExactInputParams(
      _path, unwrapETH ? address(this) : to, _amountIn, _minAmountOut
    );
    amountOutput = v3Router.exactInput( params );
    if (unwrapETH) { // Get ETH at the end
        uint256 wethBalance = IERC20(weth).balanceOf(address(this));
        IWETH(weth).withdraw(wethBalance);
        payable(to).transfer(address(this).balance);
    }
  }

  function setExecutor(address _newExecutor) external onlyOwner {
    emit ExecutorUpdated(executor, _newExecutor);
    executor = _newExecutor;
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