// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

interface IRouter {
    function WETH() external pure returns (address);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface IWETH {
    function deposit() external payable;
    function transfer(address to, uint256 value) external returns (bool);
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

contract FeeSimulator {
    uint256 MAX_INT = 2**256 - 1;
    IRouter public uniswapV2;
    
    constructor(address _uniswapV2) {
        uniswapV2 = IRouter(_uniswapV2);
    }

    // Turns a path the inverted way for the opposite swap
    function invertPath(address[] calldata _path) public pure returns(address[] memory) {
        address[] memory invertedPath = new address[](_path.length);
        for (uint256 i = 0; i < _path.length; i++) {
            invertedPath[i] = _path[_path.length - 1 - i];
        }
        return invertedPath;
    }

    // To get the fees from the simulation
    function simulateGetFeeData(uint256 _amountIn, address[] calldata _path) external payable returns(uint256[6] memory) {
        IERC20 baseToken = IERC20(_path[0]);
        IERC20 targetToken = IERC20(_path[_path.length - 1]);
        baseToken.approve(address(uniswapV2), MAX_INT);
        targetToken.approve(address(uniswapV2), MAX_INT);

        // Buy token
        uint256 initialBalance = targetToken.balanceOf(address(this));
        uint256 expectedBalance1 = uniswapV2.getAmountsOut(_amountIn, _path)[_path.length - 1];
        uint256 usedGas = gasleft();
        uniswapV2.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            _amountIn, 
            0, 
            _path, 
            address(this), 
            block.timestamp + 5 minutes
        );
        uint256 usedGas1 = usedGas - gasleft();
        uint256 finalBalance = targetToken.balanceOf(address(this));
        uint256 finalAmount1 = finalBalance - initialBalance;

        // Sell token
        uint256 initialBalance2 = baseToken.balanceOf(address(this));
        address[] memory invertedPath = invertPath(_path);
        uint256 expectedBalance2 = uniswapV2.getAmountsOut(finalAmount1, invertedPath)[invertedPath.length - 1];
        uint256 usedGasSecond = gasleft();
        uniswapV2.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            finalAmount1, 
            0, 
            invertedPath,
            address(this), 
            block.timestamp + 5 minutes
        );
        uint256 usedGas2 = usedGasSecond - gasleft();
        uint256 finalBalance2 = baseToken.balanceOf(address(this));
        uint256 finalAmount2 = finalBalance2 - initialBalance2;

        return [
            finalAmount1,
            expectedBalance1,
            finalAmount2,
            expectedBalance2,
            usedGas1,
            usedGas2
        ];
    }
}