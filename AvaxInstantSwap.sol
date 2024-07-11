// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

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

contract AvaxInstantSwap is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  ILBRouter public lbRouter;
  IQuoter public lbQuoter;
  address public wethToken;
  address public usdc;
  address public executor;

  //////////================= Events ====================================================
  event SwapFromUSDC(
    address indexed receiver,
    address indexed token,
    uint256 amountIn,
    uint256 time
  );

  event ExecutorUpdated(address indexed oldExecutor, address indexed newExecutor);

  modifier onlyExecutor() {
    require(msg.sender == executor, "not executor");
    _;
  }

  constructor(
    address _lbRouter,
    address _lbQuoter,
    address _usdc,
    address _executor
  ) Ownable(msg.sender) {
    lbRouter = ILBRouter(_lbRouter);
    lbQuoter = IQuoter(_lbQuoter);
    wethToken = address(lbRouter.getWNATIVE());
    usdc = _usdc;
    executor = _executor;
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

  function swapFromUSDC(
    address _tokenB,
    uint256 _amountIn,
    uint256 _minAmountOut,
    address[] memory _path,
    address _to,
    bool _unwrappETH
  ) public nonReentrant onlyExecutor {
    if(_tokenB == usdc) {
      emit SwapFromUSDC(_to, _tokenB, _amountIn, block.timestamp);
      IERC20(usdc).transfer(_to, _amountIn);
      return;
    }
    if (IERC20(usdc).allowance(address(this), address(lbRouter)) < _amountIn) {
        IERC20(usdc).approve(address(lbRouter), _amountIn);
    }
    ILBRouter.Path memory pathQuote = getQuote(_path, _amountIn);
    // Make LBRouter swap
    if (_unwrappETH) {
        lbRouter.swapExactTokensForNATIVESupportingFeeOnTransferTokens(
            _amountIn,
            _minAmountOut, // Amount out min
            pathQuote,
            payable(_to),
            block.timestamp + 1 hours
        );     
    } else {
        lbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn,
            _minAmountOut, // Amount out min
            pathQuote,
            _to,
            block.timestamp + 1 hours
        );
    }
    emit SwapFromUSDC(_to, _tokenB, _amountIn, block.timestamp);
  }

  function setExecutor(address _newExecutor) external onlyOwner {
    emit ExecutorUpdated(executor, _newExecutor);
    executor = _newExecutor;
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
    IERC20(_token).transfer(owner(), amount);
  }

  receive() external payable {}

  fallback() external payable {}
}