// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
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

contract SameChainSwapAvax is Ownable2Step {
  using SafeERC20 for IERC20;

  uint256 public platformFee; // Fee must be by 1000, so if you want 5% this will be 5000
  address public feeReceiver;
  uint256 public constant feeBps = 1000; // 1000 is 1% so we can have many decimals

  ILBRouter public immutable lbRouter;
  IQuoter public immutable lbQuoter;
  address public immutable wethToken;
  uint256 public constant MAX_PLATFORM_FEE = 2000; // 20% in basis points
  uint256 public threshold = 1 * 10**18;

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
  event FeeSent(address feeReceiver, uint256 amount);

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
    
  function changeFeeData(uint256 _fee, address _feeReceiver, uint256 _threshold) external onlyOwner {
    require(_fee <= MAX_PLATFORM_FEE, "Platform fee exceeds the maximum limit");
    address oldReceiver = feeReceiver;
    platformFee = _fee;
    feeReceiver = _feeReceiver;
    threshold = _threshold;
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
    bool _unwrappETH,
    uint256 _amountIn,
    uint256 _minAmountOut,
    address[] memory _path,
    bool isWethIn
  ) public payable {
    // ETH -> Token
    if (!isWethIn && _tokenA == wethToken) {
      require(msg.value > 0, "invalid msg.value");
      IWNATIVE(wethToken).deposit{value: msg.value}();
    } else {
      require(msg.value == 0, "invalid msg.value");
      uint256 beforeTransfer = IERC20(_tokenA).balanceOf(address(this));
      IERC20(_tokenA).safeTransferFrom(msg.sender, address(this), _amountIn);
      uint256 afterTransfer = IERC20(_tokenA).balanceOf(address(this));
      _amountIn = afterTransfer - beforeTransfer;
    }

    uint256 amountToSwap = (msg.value > 0 ? msg.value : _amountIn);

    checkAndApproveAll(_tokenA, address(lbRouter), amountToSwap);
    uint256 output;
    if(_tokenA == wethToken) {
      amountToSwap = amountToSwap - amountToSwap * platformFee / (feeBps * 100);
      ILBRouter.Path memory pathQuote = getQuote(_path, amountToSwap);
      output = lbRouter
        .swapExactTokensForTokensSupportingFeeOnTransferTokens(
          amountToSwap,
          _minAmountOut, // Amount out min
          pathQuote,
          address(this),
          block.timestamp + 1 hours
      );
    } else if (_tokenA != wethToken && _tokenB != wethToken) {
      address[] memory path = new address[](2);
      path[0] = _path[0];
      path[1] = wethToken;
      
      uint256 feeAmount = amountToSwap * platformFee / (feeBps * 100);
      ILBRouter.Path memory pathQuoteForFee = getQuote(path, feeAmount);
      lbRouter
        .swapExactTokensForTokensSupportingFeeOnTransferTokens(
          feeAmount,
          0, // Amount out min
          pathQuoteForFee,
          address(this),
          block.timestamp + 1 hours
      );

      ILBRouter.Path memory pathQuote = getQuote(_path, amountToSwap-feeAmount);
      output = lbRouter
        .swapExactTokensForTokensSupportingFeeOnTransferTokens(
          amountToSwap-feeAmount,
          _minAmountOut, // Amount out min
          pathQuote,
          address(this),
          block.timestamp + 1 hours
      );
    } else {
      ILBRouter.Path memory pathQuote = getQuote(_path, amountToSwap);
      output = lbRouter
        .swapExactTokensForTokensSupportingFeeOnTransferTokens(
          amountToSwap,
          _minAmountOut, // Amount out min
          pathQuote,
          address(this),
          block.timestamp + 1 hours
      );
      output = output - output * platformFee / (feeBps * 100);
    }


    if (_unwrappETH && _tokenB == wethToken) {
      IWNATIVE(wethToken).withdraw(output);
      // payable(msg.sender).transfer(output);
      (bool success, ) = msg.sender.call{value: output}("");
      if(!success) {
        revert FailedCall();
      }
    } else {
      IERC20(_tokenB).safeTransfer(msg.sender, output);
    }

    if (IWNATIVE(wethToken).balanceOf(address(this)) > 0) {
      IWNATIVE(wethToken).withdraw(IWNATIVE(wethToken).balanceOf(address(this)));
      payable(feeReceiver).transfer(address(this).balance);
      emit FeeSent(feeReceiver, address(this).balance);
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

  receive() external payable {}

  fallback() external payable {}
}