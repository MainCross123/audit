// SPDX-License-Identifier: MIT
pragma solidity =0.8.20;

interface IToken {
    function totalSupply() external view returns (uint256);

    function decimals() external view returns (uint8);

    function symbol() external view returns (string memory);

    function name() external view returns (string memory);

    function getOwner() external view returns (address);

    function balanceOf(address account) external view returns (uint256);

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function allowance(address _owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
}

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

contract FeeSimulator {
    uint256 MAX_INT = 2**256 - 1;
    address public owner;
    IRouter public router;
    
    constructor(address _router) {
        owner = msg.sender;
        router = IRouter(_router);
    }

    function swapAndGetGas(uint256 amountIn, address[] memory path) internal returns (uint256){
        uint256 usedGas = gasleft();
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, 
            0, 
            path, 
            address(this), 
            block.timestamp + 100
        );

        usedGas = usedGas - gasleft();
        return usedGas;
    }

    function check(address[] calldata path) external payable returns(uint256[6] memory) {
        require(path.length == 2);

        IToken baseToken = IToken(path[0]);
        IToken targetToken = IToken(path[1]);

        uint tokenBalance;
        address[] memory routePath = new address[](2);
        uint expectedAmountsOut;

        if(path[0] == router.WETH()) {
            IWETH wbnb = IWETH(router.WETH());
            wbnb.deposit{value: msg.value}();

            tokenBalance = baseToken.balanceOf(address(this));
            expectedAmountsOut = router.getAmountsOut(msg.value, path)[1];
        } else {
            routePath[0] = router.WETH();
            routePath[1] = path[0];
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
                0,
                routePath,
                address(this), 
                block.timestamp + 100
            );
            tokenBalance = baseToken.balanceOf(address(this));
            expectedAmountsOut = router.getAmountsOut(tokenBalance, path)[1];
        }

        // approve token
        baseToken.approve(address(router), MAX_INT);
        targetToken.approve(address(router), MAX_INT);

        uint estimatedBuy = expectedAmountsOut;

        uint buyGas = swapAndGetGas(tokenBalance, path);

        tokenBalance = targetToken.balanceOf(address(this));

        uint exactBuy = tokenBalance;

        //swap Path
        routePath[0] = path[1];
        routePath[1] = path[0];

        expectedAmountsOut = router.getAmountsOut(tokenBalance, routePath)[1];

        uint estimatedSell = expectedAmountsOut;

        uint sellGas = swapAndGetGas(tokenBalance, routePath);

        tokenBalance = baseToken.balanceOf(address(this));

        uint exactSell = tokenBalance;

        return [
            buyGas,
            sellGas,
            estimatedBuy,
            exactBuy,
            estimatedSell,
            exactSell
        ];
    }
}