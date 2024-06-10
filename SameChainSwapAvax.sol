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

  mapping(address => bool) public feeTokens;
  uint256 public platformFee; // Fee must be by 1000, so if you want 5% this will be 5000
  address public feeReceiver;
  uint256 public constant feeBps = 1000; // 1000 is 1% so we can have many decimals

  ILBRouter public lbRouter;
  IQuoter public lbQuoter;
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
    address _lbRouter,
    address _lbQuoter
  ) Ownable(msg.sender) {
    platformFee = _fee;
    feeReceiver = _feeReceiver;
    lbRouter = ILBRouter(_lbRouter);
    lbQuoter = IQuoter(_lbQuoter);
    wethToken = address(lbRouter.getWNATIVE());
  }
    uint256 public constant MAX_PLATFORM_FEE = 2000; // 20% in basis points
  function changeFeeData(uint256 _fee, address _feeReceiver) external onlyOwner {
    require(_fee <= MAX_PLATFORM_FEE, "Platform fee exceeds the maximum limit");
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

    address feeToken = identifyFeeToken(_tokenA, _tokenB);

    uint256 amountIn = (msg.value > 0 ? msg.value : _amountIn);

    uint256 amountToSwap = amountIn;

    if (feeToken == _tokenA || feeToken == address(0)) {
      amountToSwap = deductFees(amountIn, _tokenA);
    }

    checkAndApproveAll(_tokenA, address(lbRouter), amountToSwap);

    ILBRouter.Path memory pathQuote = getQuote(_path, amountToSwap);
    uint256 output = lbRouter
      .swapExactTokensForTokensSupportingFeeOnTransferTokens(
        amountToSwap,
        _minAmountOut, // Amount out min
        pathQuote,
        address(this),
        block.timestamp + 1 hours
    );

    if (feeToken == _tokenB) {
      output = deductFees(output, _tokenB);
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