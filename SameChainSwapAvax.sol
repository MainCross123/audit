// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWNATIVE is IERC20 {
  function deposit() external payable;
  function withdraw(uint256) external;
}

interface ILBRouter {
  enum Version {
    V1,
    V2,
    V2_1
  }
  struct Path {
    uint256[] pairBinSteps;
    Version[] versions;
    IERC20[] tokenPath;
  }

  function swapExactTokensForTokensSupportingFeeOnTransferTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    Path memory path,
    address to,
    uint256 deadline
  ) external returns (uint256 amountOut);
  function swapExactTokensForNATIVESupportingFeeOnTransferTokens(
    uint256 amountIn,
    uint256 amountOutMinNATIVE,
    Path memory path,
    address payable to,
    uint256 deadline
  ) external returns (uint256 amountOut);
  function getWNATIVE() external view returns (IWNATIVE);
}

interface IQuoter {
  struct Quote {
    address[] route;
    address[] pairs;
    uint256[] binSteps;
    ILBRouter.Version[] versions;
    uint128[] amounts;
    uint128[] virtualAmountsWithoutSlippage;
    uint128[] fees;
  }

  function findBestPathFromAmountIn(
    address[] calldata route,
    uint128 amountIn
  ) external view returns (Quote memory quote);
}

contract SameChainSwapAvax is Ownable {
  using SafeERC20 for IERC20;

  uint256 public platformFee; // Fee must be by 1000, so if you want 5% this will be 5000
  address public feeReceiver;
  uint256 public constant feeBps = 1000; // 1000 is 1% so we can have many decimals

  ILBRouter public lbRouter;
  IQuoter public lbQuoter;
  address public wethToken;

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

  constructor(
    uint256 _fee,
    address _feeReceiver,
    address _lbRouter,
    address _lbQuoter
  ) Ownable(msg.sender) {
    platformFee = _fee;
    feeReceiver = _feeReceiver;
    lbRouter = ILBRouter(_lbRouter);
    lbQuoter = IQuoter(_lbQuoter);
    wethToken = address(lbRouter.getWNATIVE());
  }

 function changeFeeData(uint256 _fee, address _feeReceiver) external onlyOwner {
    address oldReceiver = feeReceiver;
    platformFee = _fee;
    feeReceiver = _feeReceiver;
    emit FeeReceiverSet(oldReceiver, _feeReceiver);
  }

  // To get the estimated path for making a swap
  function getQuote(
    address[] memory _path,
    uint256 _amountIn
  ) public view returns (ILBRouter.Path memory) {
    // Use the quoter to find the best route for the swap
    address[] memory path = new address[](_path.length);
    IERC20[] memory pathToken = new IERC20[](_path.length);
    for (uint256 i = 0; i < _path.length; i++) {
      path[i] = _path[i];
      pathToken[i] = IERC20(_path[i]);
    }
    IQuoter.Quote memory quote = lbQuoter.findBestPathFromAmountIn(
      path,
      uint128(_amountIn)
    );
    ILBRouter.Path memory myPath = ILBRouter.Path({
      pairBinSteps: quote.binSteps,
      versions: quote.versions,
      tokenPath: pathToken
    });
    return myPath;
  }

  function swapOnce(
    address _tokenA,
    address _tokenB,
    uint256 _amountIn,
    uint256 _minAmountOut,
    address[] memory _path,
    bool isWethIn
  ) public payable {
    // ETH -> Token
    if (!isWethIn && _tokenA == wethToken) {
      IWNATIVE(wethToken).deposit{value: msg.value}();
    } else {
      IERC20(_tokenA).safeTransferFrom(msg.sender, address(this), _amountIn);
    }
    uint256 amountIn = (msg.value > 0 ? msg.value : _amountIn);
    uint256 feeAmount = (amountIn * platformFee) / (feeBps * 100);
    uint256 amountAfterFee = amountIn - feeAmount;
    IERC20(_tokenA).safeTransfer(feeReceiver, feeAmount); // Fee in tokenA

    checkAndApproveAll(_tokenA, address(lbRouter), amountAfterFee);

    ILBRouter.Path memory pathQuote = getQuote(_path, amountAfterFee);
    uint256 output = lbRouter
      .swapExactTokensForTokensSupportingFeeOnTransferTokens(
        amountAfterFee,
        _minAmountOut, // Amount out min
        pathQuote,
        address(this),
        block.timestamp * 5 minutes
      );

    if (_tokenB == wethToken) {
      IWNATIVE(wethToken).withdraw(output);
      payable(msg.sender).transfer(output);
    } else {
      IERC20(_tokenB).safeTransfer(msg.sender, output);
    }

    emit SwapExecuted(_tokenA, _tokenB, _amountIn, output);
  }

  function checkAndApproveAll(
    address _token,
    address _target,
    uint256 _amountToCheck
  ) internal {
    if (IERC20(_token).allowance(address(this), _target) < _amountToCheck) {
      IERC20(_token).forceApprove(_target, 0);
      IERC20(_token).forceApprove(_target, ~uint256(0));
    }
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