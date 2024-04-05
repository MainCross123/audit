// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/src/v0.8/ccip/applications/CCIPReceiver.sol";
import {IERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableMap} from "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.0/contracts/utils/structs/EnumerableMap.sol";

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
    function _contextSuffixLength() internal view virtual returns (uint256) {
        return 0;
    }
}

abstract contract Ownable is Context {
    address private _owner;
    error OwnableUnauthorizedAccount(address account);
    error OwnableInvalidOwner(address owner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(initialOwner);
    }
    modifier onlyOwner() {
        _checkOwner();
        _;
    }
    function owner() public view virtual returns (address) {
        return _owner;
    }
    function _checkOwner() internal view virtual {
        if (owner() != _msgSender()) {
            revert OwnableUnauthorizedAccount(_msgSender());
        }
    }
    function renounceOwnership() public virtual onlyOwner {
        _transferOwnership(address(0));
    }
    function transferOwnership(address newOwner) public virtual onlyOwner {
        if (newOwner == address(0)) {
            revert OwnableInvalidOwner(address(0));
        }
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal virtual {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

interface IWNATIVE is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface ILBRouter {
    enum Version { V1, V2, V2_1 }
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
    
    function findBestPathFromAmountIn(address[] calldata route, uint128 amountIn)
        external
        view
    returns (Quote memory quote);
}

/// @title - A simple messenger contract for transferring/receiving tokens and data across chains.
/// @dev - This example shows how to recover tokens in case of revert
contract CCIP_AVAX is CCIPReceiver, Ownable {
    using EnumerableMap for EnumerableMap.Bytes32ToUintMap;
    using SafeERC20 for IERC20;

    // Custom errors to provide more descriptive revert messages.
    error NotEnoughBalance(uint256 currentBalance, uint256 calculatedFees); // Used to make sure contract has enough balance to cover the fees.
    error NothingToWithdraw(); // Used when trying to withdraw Ether but there's nothing to withdraw.
    error FailedToWithdrawEth(address owner, address target, uint256 value); // Used when the withdrawal of Ether fails.
    error DestinationChainNotAllowlisted(uint64 destinationChainSelector); // Used when the destination chain has not been allowlisted by the contract owner.
    error SourceChainNotAllowed(uint64 sourceChainSelector); // Used when the source chain has not been allowlisted by the contract owner.
    error SenderNotAllowed(address sender); // Used when the sender has not been allowlisted by the contract owner.
    error InvalidReceiverAddress(); // Used when the receiver address is 0.
    error OnlySelf(); // Used when a function is called outside of the contract itself.
    error ErrorCase(); // Used when simulating a revert during message processing.
    error MessageNotFailed(bytes32 messageId);

    // Example error code, could have many different error codes.
    enum ErrorCode {
        // RESOLVED is first so that the default value is resolved.
        RESOLVED,
        // Could have any number of error codes here.
        FAILED
    }

    struct FailedMessage {
        bytes32 messageId;
        ErrorCode errorCode;
    }

    struct FailedMessagesUsers {
        address token;
        address receiver;
        uint256 amount;
        bool isRedeemed;
        bytes32 messageId;
    }

    struct AddressNumber {
        address user;
        uint256 index;
    }

    // Event emitted when a message is sent to another chain.
    event MessageSent(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed destinationChainSelector, // The chain selector of the destination chain.
        address receiver, // The address of the receiver on the destination chain.
        string text, // The text being sent.
        address token, // The token address that was transferred.
        uint256 tokenAmount, // The token amount that was transferred.
        address feeToken, // the token address used to pay CCIP fees.
        uint256 fees // The fees paid for sending the message.
    );

    // Event emitted when a message is received from another chain.
    event MessageReceived(
        bytes32 indexed messageId, // The unique ID of the CCIP message.
        uint64 indexed sourceChainSelector, // The chain selector of the source chain.
        address sender, // The address of the sender from the source chain.
        string text, // The text that was received.
        address token, // The token address that was transferred.
        uint256 tokenAmount // The token amount that was transferred.
    );

    event MessageFailed(bytes32 indexed messageId, bytes reason);
    event MessageRecovered(bytes32 indexed messageId);

    bytes32 private s_lastReceivedMessageId; // Store the last received messageId.
    address private s_lastReceivedTokenAddress; // Store the last received token address.
    uint256 private s_lastReceivedTokenAmount; // Store the last received amount.
    string private s_lastReceivedText; // Store the last received text.

    // Mapping to keep track of allowlisted destination chains.
    mapping(uint64 => bool) public allowlistedDestinationChains;

    // Mapping to keep track of allowlisted source chains.
    mapping(uint64 => bool) public allowlistedSourceChains;

    // Mapping to keep track of allowlisted senders.
    mapping(address => bool) public allowlistedSenders;

    IERC20 private s_linkToken;
    address public wAVAX;
    address public usdc;

    // The message contents of failed messages are stored here.
    mapping(bytes32 messageId => Client.Any2EVMMessage contents) public s_messageContents;

    // User => FailedMessagesUsers[]
    mapping (address => FailedMessagesUsers[]) public failedMessagesUsers;
    // MessageId => (address, number)
    mapping (bytes32 => AddressNumber) public failedMessageByMessageId;

    // Contains failed messages and their state.
    EnumerableMap.Bytes32ToUintMap internal s_failedMessages;
    ILBRouter public lbRouter;
    IQuoter public lbQuoter;
    uint256 public swapFee; // Fee must be by 1000, so if you want 5% this will be 5000
    address public feeReceiver;
    uint256 public constant feeBps = 1000; // 1000 is 1% so we can have many decimals

    /// @notice Constructor initializes the contract with the router address.
    /// @param _router The address of the router contract.
    /// @param _link The address of the link contract.
    constructor(
        address _router,
        address _link,
        address _usdc,
        address _lbRouter,
        address _lbQuoter,
        uint256 _swapFee,
        address _feeReceiver
    ) CCIPReceiver(_router) Ownable(msg.sender) {
        s_linkToken = IERC20(_link);
        lbRouter = ILBRouter(_lbRouter);
        lbQuoter = IQuoter(_lbQuoter);
        usdc = _usdc;
        wAVAX = address(lbRouter.getWNATIVE());
        swapFee = _swapFee;
        feeReceiver = _feeReceiver;
    }

    /// @dev Modifier that checks if the chain with the given destinationChainSelector is allowlisted.
    /// @param _destinationChainSelector The selector of the destination chain.
    modifier onlyAllowlistedDestinationChain(uint64 _destinationChainSelector) {
        if (!allowlistedDestinationChains[_destinationChainSelector])
            revert DestinationChainNotAllowlisted(_destinationChainSelector);
        _;
    }

    /// @dev Modifier that checks if the chain with the given sourceChainSelector is allowlisted and if the sender is allowlisted.
    /// @param _sourceChainSelector The selector of the destination chain.
    /// @param _sender The address of the sender.
    modifier onlyAllowlisted(uint64 _sourceChainSelector, address _sender) {
        if (!allowlistedSourceChains[_sourceChainSelector])
            revert SourceChainNotAllowed(_sourceChainSelector);
        if (!allowlistedSenders[_sender]) revert SenderNotAllowed(_sender);
        _;
    }

    /// @dev Modifier that checks the receiver address is not 0.
    /// @param _receiver The receiver address.
    modifier validateReceiver(address _receiver) {
        if (_receiver == address(0)) revert InvalidReceiverAddress();
        _;
    }

    /// @dev Modifier to allow only the contract itself to execute a function.
    /// Throws an exception if called by any account other than the contract itself.
    modifier onlySelf() {
        if (msg.sender != address(this)) revert OnlySelf();
        _;
    }

    function changeFeeAndAddress(uint256 _fee, address _feeReceiver) external onlyOwner {
        swapFee = _fee;
        feeReceiver = _feeReceiver;
    }

    function changeRouters(address _lbRouter, address _lbQuoter) external onlyOwner {
        lbRouter = ILBRouter(_lbRouter);
        lbQuoter = IQuoter(_lbQuoter);
    }

    /// @dev Updates the allowlist status of a destination chain for transactions.
    /// @notice This function can only be called by the owner.
    /// @param _destinationChainSelector The selector of the destination chain to be updated.
    /// @param allowed The allowlist status to be set for the destination chain.
    function allowlistDestinationChain(
        uint64 _destinationChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedDestinationChains[_destinationChainSelector] = allowed;
    }

    /// @dev Updates the allowlist status of a source chain
    /// @notice This function can only be called by the owner.
    /// @param _sourceChainSelector The selector of the source chain to be updated.
    /// @param allowed The allowlist status to be set for the source chain.
    function allowlistSourceChain(
        uint64 _sourceChainSelector,
        bool allowed
    ) external onlyOwner {
        allowlistedSourceChains[_sourceChainSelector] = allowed;
    }

    /// @dev Updates the allowlist status of a sender for transactions.
    /// @notice This function can only be called by the owner.
    /// @param _sender The address of the sender to be updated.
    /// @param allowed The allowlist status to be set for the sender.
    function allowlistSender(address _sender, bool allowed) external onlyOwner {
        allowlistedSenders[_sender] = allowed;
    }

    /// @notice Sends data and transfer tokens to receiver on the destination chain.
    /// @notice Pay for fees in LINK.
    /// @dev Assumes your contract has sufficient LINK to pay for CCIP fees.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _receiver The address of the recipient on the destination blockchain.
    /// @param _text The string data to be sent.
    /// @param _token token address.
    /// @param _amount token amount.
    /// @return messageId The ID of the CCIP message that was sent.
    function sendMessagePayLINK(
        uint64 _destinationChainSelector,
        address _receiver,
        string memory _text,
        address _token,
        uint256 _amount,
        uint256 _gasLimitReceiver
    )
        internal
        onlyAllowlistedDestinationChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (bytes32 messageId)
    {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(linkToken) means fees are paid in LINK
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _text,
            _token,
            _amount,
            address(s_linkToken),
            _gasLimitReceiver
        );

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());

        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);

        if (fees > s_linkToken.balanceOf(address(this)))
            revert NotEnoughBalance(s_linkToken.balanceOf(address(this)), fees);

        // approve the Router to transfer LINK tokens on contract's behalf. It will spend the fees in LINK
        s_linkToken.approve(address(router), fees);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        if (IERC20(_token).allowance(address(this), address(router)) < _amount) {
            IERC20(_token).safeApprove(address(router), 0);
            IERC20(_token).safeApprove(address(router), ~uint256(0));
        }

        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend(_destinationChainSelector, evm2AnyMessage);

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            _text,
            _token,
            _amount,
            address(s_linkToken),
            fees
        );

        // Return the message ID
        return messageId;
    }

    /// @notice Sends data and transfer tokens to receiver on the destination chain.
    /// @notice Pay for fees in native gas.
    /// @dev Assumes your contract has sufficient native gas like ETH on Ethereum or MATIC on Polygon.
    /// @param _destinationChainSelector The identifier (aka selector) for the destination blockchain.
    /// @param _receiver The address of the recipient on the destination blockchain.
    /// @param _text The string data to be sent.
    /// @param _token token address.
    /// @param _amount token amount.
    /// @return messageId The ID of the CCIP message that was sent.
    function sendMessagePayNative(
        uint64 _destinationChainSelector,
        address _receiver,
        string memory _text,
        address _token,
        uint256 _amount,
        uint256 _gasLimitReceiver,
        uint256 _valueAvailable
    )
        internal
        onlyAllowlistedDestinationChain(_destinationChainSelector)
        validateReceiver(_receiver)
        returns (bytes32 messageId)
    {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            _text,
            _token,
            _amount,
            address(0),
            _gasLimitReceiver
        );

        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());

        // Get the fee required to send the CCIP message
        uint256 fees = router.getFee(_destinationChainSelector, evm2AnyMessage);

        if (fees > address(this).balance)
            revert NotEnoughBalance(address(this).balance, fees);

        // approve the Router to spend tokens on contract's behalf. It will spend the amount of the given token
        if (IERC20(_token).allowance(address(this), address(router)) < _amount) {
            IERC20(_token).safeApprove(address(router), 0);
            IERC20(_token).safeApprove(address(router), ~uint256(0));
        }
        
        // Send the message through the router and store the returned message ID
        messageId = router.ccipSend{value: fees}(
            _destinationChainSelector,
            evm2AnyMessage
        );

        payable(msg.sender).transfer(_valueAvailable - fees); // Refund the remaining msg.value

        // Emit an event with message details
        emit MessageSent(
            messageId,
            _destinationChainSelector,
            _receiver,
            _text,
            _token,
            _amount,
            address(0),
            fees
        );

        // Return the message ID
        return messageId;
    }

    // To get the estimated path for making a swap
    function getQuote(address[] memory _path, uint256 _amountIn) public view returns(ILBRouter.Path memory) {
        // Use the quoter to find the best route for the swap
        address[] memory path = new address[](_path.length);
        IERC20[] memory pathToken = new IERC20[](_path.length);
        for (uint256 i = 0; i < _path.length; i++) {
            path[i] = _path[i];
            pathToken[i] = IERC20(_path[i]);
        }
        IQuoter.Quote memory quote = lbQuoter.findBestPathFromAmountIn(path, uint128(_amountIn));
        ILBRouter.Path memory myPath = ILBRouter.Path({
            pairBinSteps: quote.binSteps,
            versions: quote.versions,
            tokenPath: pathToken
        });
        return myPath;
    }

    /*** My functions ***/
    struct ReceiverSwapData {
        address finalToken;
        address userReceiver;
        uint256 minAmountOut;
        uint256 minAmountOutV2Swap;
        bool isV2;
        bytes path;
        address[] v2Path;
    }
    struct InitialSwapData {
        address tokenIn;   // Token you're sending for a crosschain swap
        uint256 amountIn;  // For the token you send
        uint256 minAmountOut;  // Note how this is different
        bool unwrappedAVAX;
        ILBRouter.Path path; // Note how this is different
    }

    // Approves from this to the target contract unlimited tokens
    function checkAndApproveAll(address _token, address _target, uint256 _amountToCheck) internal {
        if (IERC20(_token).allowance(address(this), _target) < _amountToCheck) {
            IERC20(_token).safeApprove(_target, 0);
            IERC20(_token).safeApprove(_target, ~uint256(0));
        }
    }

    function swapInitialData(
        InitialSwapData memory _initialSwapData,
        uint256 _realAmountIn
    ) internal returns(uint256 USDCOut) {
        if (_initialSwapData.tokenIn == usdc) {
            // Step a)
            USDCOut = _realAmountIn;
        } else {
            // Step b) first we check the output token is USDC
            address outputToken = address(_initialSwapData.path.tokenPath[_initialSwapData.path.tokenPath.length - 1]);
            require(outputToken == usdc, 'Must swap to USDC');
            checkAndApproveAll(_initialSwapData.tokenIn, address(lbRouter), _realAmountIn);
            USDCOut = lbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                _realAmountIn,
                _initialSwapData.minAmountOut, // Amount out min
                _initialSwapData.path,
                address(this),
                99999999999999999999
            );
        }
        // Send the fee
        uint256 feeAmount = USDCOut * swapFee / (feeBps * 100);
        IERC20(usdc).safeTransfer(feeReceiver, feeAmount);
        USDCOut = USDCOut - feeAmount;
    }

    // The token that will be crossed is always USDC
    function sendMessagePayFirstStep(
        uint64 _destinationChainSelector,
        address _receiverCCIPInOtherChain,
        uint256 _gasLimitReceiver, // How much gas the receiver will have to work with
        bool _isLinkOrNative,   // True = LINK, false = Native
        InitialSwapData memory _initialSwapData,
        ReceiverSwapData memory _receiverSwapData
    )
        external
        payable
        onlyAllowlistedDestinationChain(_destinationChainSelector)
        validateReceiver(_receiverCCIPInOtherChain)
        returns (bytes32 messageId)
    {
        uint256 valueAvailable = msg.value;
        // Some tokens have transfer fees so we check the real amount we get after the transfer from
        uint256 realAmountIn;
        if (!_initialSwapData.unwrappedAVAX && _initialSwapData.tokenIn == wAVAX) {
            IWNATIVE(wAVAX).deposit{value: msg.value - _initialSwapData.amountIn}(); // _initialSwapData.amountIn will be the ccip fee
            valueAvailable = _initialSwapData.amountIn;
            realAmountIn = msg.value - _initialSwapData.amountIn;
        } else {
            uint256 initialBalance = IERC20(_initialSwapData.tokenIn).balanceOf(address(this));
            IERC20(_initialSwapData.tokenIn).safeTransferFrom(msg.sender, address(this), _initialSwapData.amountIn);
            uint256 currentBalance = IERC20(_initialSwapData.tokenIn).balanceOf(address(this));
            realAmountIn = currentBalance - initialBalance;
        }
        uint256 USDCOut = swapInitialData(_initialSwapData, realAmountIn);

        if (_isLinkOrNative) {
            return sendMessagePayLINK(
                _destinationChainSelector,
                _receiverCCIPInOtherChain,
                string(abi.encode(
                    _receiverSwapData
                )),
                usdc,
                USDCOut,
                _gasLimitReceiver
            );
        } else {
            return sendMessagePayNative(
                _destinationChainSelector,
                _receiverCCIPInOtherChain,
                string(abi.encode(
                    _receiverSwapData
                )),
                usdc,
                USDCOut,
                _gasLimitReceiver,
                valueAvailable
            );
        }
    }

    function calculateFeeGas(
        uint64 _destinationChainSelector,
        address _receiver,
        address _token,
        uint256 _amount,
        uint256 _gasLimitReceiver,
        bool _payInLINK,
        ReceiverSwapData memory _receiverSwapData
    ) external view returns (uint256 fees) {
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        // address(0) means fees are paid in native gas
        Client.EVM2AnyMessage memory evm2AnyMessage = _buildCCIPMessage(
            _receiver,
            string(abi.encode(_receiverSwapData)),
            _token,
            _amount,
            _payInLINK ? address(s_linkToken) : address(0),
            _gasLimitReceiver
        );
        // Initialize a router client instance to interact with cross-chain router
        IRouterClient router = IRouterClient(this.getRouter());
        // Get the fee required to send the CCIP message
        fees = router.getFee(_destinationChainSelector, evm2AnyMessage);
    }
    /*** My functions ***/

    /**
     * @notice Returns the details of the last CCIP received message.
     * @dev This function retrieves the ID, text, token address, and token amount of the last received CCIP message.
     * @return messageId The ID of the last received CCIP message.
     * @return text The text of the last received CCIP message.
     * @return tokenAddress The address of the token in the last CCIP received message.
     * @return tokenAmount The amount of the token in the last CCIP received message.
     */
    function getLastReceivedMessageDetails()
        public
        view
        returns (
            bytes32 messageId,
            string memory text,
            address tokenAddress,
            uint256 tokenAmount
        )
    {
        return (
            s_lastReceivedMessageId,
            s_lastReceivedText,
            s_lastReceivedTokenAddress,
            s_lastReceivedTokenAmount
        );
    }

    /**
     * @notice Retrieves a paginated list of failed messages.
     * @dev This function returns a subset of failed messages defined by `offset` and `limit` parameters. It ensures that the pagination parameters are within the bounds of the available data set.
     * @param offset The index of the first failed message to return, enabling pagination by skipping a specified number of messages from the start of the dataset.
     * @param limit The maximum number of failed messages to return, restricting the size of the returned array.
     * @return failedMessages An array of `FailedMessage` struct, each containing a `messageId` and an `errorCode` (RESOLVED or FAILED), representing the requested subset of failed messages. The length of the returned array is determined by the `limit` and the total number of failed messages.
     */
    function getFailedMessages(
        uint256 offset,
        uint256 limit
    ) external view returns (FailedMessage[] memory) {
        uint256 length = s_failedMessages.length();

        // Calculate the actual number of items to return (can't exceed total length or requested limit)
        uint256 returnLength = (offset + limit > length)
            ? length - offset
            : limit;
        FailedMessage[] memory failedMessages = new FailedMessage[](
            returnLength
        );

        // Adjust loop to respect pagination (start at offset, end at offset + limit or total length)
        for (uint256 i = 0; i < returnLength; i++) {
            (bytes32 messageId, uint256 errorCode) = s_failedMessages.at(
                offset + i
            );
            failedMessages[i] = FailedMessage(messageId, ErrorCode(errorCode));
        }
        return failedMessages;
    }

    /// @notice The entrypoint for the CCIP router to call. This function should
    /// never revert, all errors should be handled internally in this contract.
    /// @param any2EvmMessage The message to process.
    /// @dev Extremely important to ensure only router calls this.
    function ccipReceive(
        Client.Any2EVMMessage calldata any2EvmMessage
    )
        external
        override
        onlyRouter
        onlyAllowlisted(
            any2EvmMessage.sourceChainSelector,
            abi.decode(any2EvmMessage.sender, (address))
        ) // Make sure the source chain and sender are allowlisted
    {
        /* solhint-disable no-empty-blocks */
        try this.processMessage(any2EvmMessage) {
            // Intentionally empty in this example; no action needed if processMessage succeeds
        } catch (bytes memory err) {
            // Could set different error codes based on the caught error. Each could be
            // handled differently.
            s_failedMessages.set(
                any2EvmMessage.messageId,
                uint256(ErrorCode.FAILED)
            );
            s_messageContents[any2EvmMessage.messageId] = any2EvmMessage;

            /*- My code -*/
            string memory text = abi.decode(any2EvmMessage.data, (string)); // abi-decoding of the sent text
            ReceiverSwapData memory receiverData = abi.decode(bytes(text), (ReceiverSwapData));
            failedMessagesUsers[receiverData.userReceiver].push(FailedMessagesUsers(
                usdc,
                receiverData.userReceiver,
                any2EvmMessage.destTokenAmounts[0].amount,
                false,
                any2EvmMessage.messageId
            ));
            failedMessageByMessageId[any2EvmMessage.messageId] = AddressNumber(
                receiverData.userReceiver, failedMessagesUsers[receiverData.userReceiver].length);
            /*- My code -*/
            
            // Don't revert so CCIP doesn't revert. Emit event instead.
            // The message can be retried later without having to do manual execution of CCIP.
            emit MessageFailed(any2EvmMessage.messageId, err);
            return;
        }
    }

    /// @notice Serves as the entry point for this contract to process incoming messages.
    /// @param any2EvmMessage Received CCIP message.
    /// @dev Transfers specified token amounts to the owner of this contract. This function
    /// must be external because of the  try/catch for error handling.
    /// It uses the `onlySelf`: can only be called from the contract.
    function processMessage(
        Client.Any2EVMMessage calldata any2EvmMessage
    )
        external
        onlySelf
    {
        _ccipReceive(any2EvmMessage); // process the message - may revert as well
    }

    /// @notice Allows the owner to retry a failed message in order to unblock the associated tokens.
    /// @param messageId The unique identifier of the failed message.
    /// @param tokenReceiver The address to which the tokens will be sent.
    /// @dev This function is only callable by the contract owner. It changes the status of the message
    /// from 'failed' to 'resolved' to prevent reentry and multiple retries of the same message.
    function retryFailedMessage(
        bytes32 messageId,
        address tokenReceiver,
        uint256 index
    ) external onlyOwner {
        // Check if the message has failed; if not, revert the transaction.
        if (s_failedMessages.get(messageId) != uint256(ErrorCode.FAILED))
            revert MessageNotFailed(messageId);

        // Set the error code to RESOLVED to disallow reentry and multiple retries of the same failed message.
        s_failedMessages.set(messageId, uint256(ErrorCode.RESOLVED));

        /*- My code -*/
        require(failedMessagesUsers[tokenReceiver][index].isRedeemed == false,
            "Already redeemed");
        failedMessagesUsers[tokenReceiver][index].isRedeemed = true;
        /*- My code -*/

        // Retrieve the content of the failed message.
        Client.Any2EVMMessage memory message = s_messageContents[messageId];

        // This example expects one token to have been sent, but you can handle multiple tokens.
        // Transfer the associated tokens to the specified receiver as an escape hatch.
        IERC20(message.destTokenAmounts[0].token).safeTransfer(
            tokenReceiver,
            message.destTokenAmounts[0].amount
        );

        // Emit an event indicating that the message has been recovered.
        emit MessageRecovered(messageId);
    }

    function _ccipReceive(
        Client.Any2EVMMessage memory any2EvmMessage
    ) internal override {
        s_lastReceivedMessageId = any2EvmMessage.messageId; // fetch the messageId
        s_lastReceivedText = abi.decode(any2EvmMessage.data, (string)); // abi-decoding of the sent text
        // Expect one token to be transferred at once, but you can transfer several tokens.
        s_lastReceivedTokenAddress = any2EvmMessage.destTokenAmounts[0].token;
        s_lastReceivedTokenAmount = any2EvmMessage.destTokenAmounts[0].amount;
        emit MessageReceived(
            any2EvmMessage.messageId,
            any2EvmMessage.sourceChainSelector, // fetch the source chain identifier (aka selector)
            abi.decode(any2EvmMessage.sender, (address)), // abi-decoding of the sender address,
            abi.decode(any2EvmMessage.data, (string)),
            any2EvmMessage.destTokenAmounts[0].token,
            any2EvmMessage.destTokenAmounts[0].amount
        );

        ReceiverSwapData memory receiverData = abi.decode(bytes(s_lastReceivedText), (ReceiverSwapData));
        // If we transfer USDC, we send this token
        if (receiverData.finalToken == usdc) return IERC20(usdc).safeTransfer(receiverData.userReceiver, s_lastReceivedTokenAmount);
        // Approve to the router
        if (IERC20(usdc).allowance(address(this), address(lbRouter)) < s_lastReceivedTokenAmount) {
            IERC20(usdc).approve(address(lbRouter), s_lastReceivedTokenAmount);
        }

        ILBRouter.Path memory pathQuote = getQuote(receiverData.v2Path, s_lastReceivedTokenAmount);

        // Make LBRouter swap
        if (!receiverData.isV2) {
            lbRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                s_lastReceivedTokenAmount,
                receiverData.minAmountOut, // Amount out min
                pathQuote,
                receiverData.userReceiver,
                99999999999999999999
            );
        } else {
            lbRouter.swapExactTokensForNATIVESupportingFeeOnTransferTokens(
                s_lastReceivedTokenAmount,
                receiverData.minAmountOut, // Amount out min
                pathQuote,
                payable(receiverData.userReceiver),
                99999999999999999999
            );
        }
    }


    /// @notice Construct a CCIP message.
    /// @dev This function will create an EVM2AnyMessage struct with all the necessary information for programmable tokens transfer.
    /// @param _receiver The address of the receiver.
    /// @param _text The string data to be sent.
    /// @param _token The token to be transferred.
    /// @param _amount The amount of the token to be transferred.
    /// @param _feeTokenAddress The address of the token used for fees. Set address(0) for native gas.
    /// @return Client.EVM2AnyMessage Returns an EVM2AnyMessage struct which contains information for sending a CCIP message.
    function _buildCCIPMessage(
        address _receiver,
        string memory _text,
        address _token,
        uint256 _amount,
        address _feeTokenAddress,
        uint256 _gasLimitReceiver
    ) internal pure returns (Client.EVM2AnyMessage memory) {
        // Set the token amounts
        Client.EVMTokenAmount[]
            memory tokenAmounts = new Client.EVMTokenAmount[](1);
        Client.EVMTokenAmount memory tokenAmount = Client.EVMTokenAmount({
            token: _token,
            amount: _amount
        });
        tokenAmounts[0] = tokenAmount;
        // Create an EVM2AnyMessage struct in memory with necessary information for sending a cross-chain message
        Client.EVM2AnyMessage memory evm2AnyMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver), // ABI-encoded receiver address
            data: abi.encode(_text), // ABI-encoded string
            tokenAmounts: tokenAmounts, // The amount and type of token being transferred
            extraArgs: Client._argsToBytes(
                // Additional arguments, setting gas limit
                Client.EVMExtraArgsV1({gasLimit: _gasLimitReceiver})
            ),
            // Set the feeToken to a feeTokenAddress, indicating specific asset will be used for fees
            feeToken: _feeTokenAddress
        });
        return evm2AnyMessage;
    }

    /// @notice Fallback function to allow the contract to receive Ether.
    /// @dev This function has no function body, making it a default function for receiving Ether.
    /// It is automatically called when Ether is sent to the contract without any data.
    receive() external payable {}

    /// @notice Allows the contract owner to withdraw the entire balance of Ether from the contract.
    /// @dev This function reverts if there are no funds to withdraw or if the transfer fails.
    /// It should only be callable by the owner of the contract.
    /// @param _beneficiary The address to which the Ether should be sent.
    function withdraw(address _beneficiary) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = address(this).balance;

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        // Attempt to send the funds, capturing the success status and discarding any return data
        (bool sent, ) = _beneficiary.call{value: amount}("");

        // Revert if the send failed, with information about the attempted transfer
        if (!sent) revert FailedToWithdrawEth(msg.sender, _beneficiary, amount);
    }

    /// @notice Allows the owner of the contract to withdraw all tokens of a specific ERC20 token.
    /// @dev This function reverts with a 'NothingToWithdraw' error if there are no tokens to withdraw.
    /// @param _beneficiary The address to which the tokens will be sent.
    /// @param _token The contract address of the ERC20 token to be withdrawn.
    function withdrawToken(
        address _beneficiary,
        address _token
    ) public onlyOwner {
        // Retrieve the balance of this contract
        uint256 amount = IERC20(_token).balanceOf(address(this));

        // Revert if there is nothing to withdraw
        if (amount == 0) revert NothingToWithdraw();

        IERC20(_token).safeTransfer(_beneficiary, amount);
    }

    /*- My functions -*/
    function recoverFailedTransfer(
        address tokenReceiver,
        uint256 index
    ) external {
        FailedMessagesUsers memory f = failedMessagesUsers[tokenReceiver][index];
        require(f.isRedeemed == false, "Already redeemed");
        failedMessagesUsers[tokenReceiver][index].isRedeemed = true;
        require(msg.sender == f.receiver, "Must be executed by the receiver");

        // Check if the message has failed; if not, revert the transaction.
        if (s_failedMessages.get(f.messageId) != uint256(ErrorCode.FAILED))
            revert MessageNotFailed(f.messageId);

        // Set the error code to RESOLVED to disallow reentry and multiple retries of the same failed message.
        s_failedMessages.set(f.messageId, uint256(ErrorCode.RESOLVED));

        // This example expects one token to have been sent, but you can handle multiple tokens.
        // Transfer the associated tokens to the specified receiver as an escape hatch.
        IERC20(f.token).safeTransfer(
            tokenReceiver,
            f.amount
        );

        // Emit an event indicating that the message has been recovered.
        emit MessageRecovered(f.messageId);
    }

    function getFailedMessagesUser(
        address _user,
        uint256 _offset,
        uint256 _limit
    ) external view returns (FailedMessagesUsers[] memory) {
        FailedMessagesUsers[] memory results = new FailedMessagesUsers[](_limit);
        for (uint256 i = 0; i < _limit; i++) {
            results[i] = failedMessagesUsers[_user][_offset+i];
        }
        return results;
    }

    function getLengthFailedMessagesUser(address _user) external view returns (uint256) {
        uint256 size = failedMessagesUsers[_user].length;
        return size;
    }

    function getFailedMessageByMessageId(bytes32 _messageId) external view returns (FailedMessagesUsers memory) {
        AddressNumber memory an = failedMessageByMessageId[_messageId];
        return failedMessagesUsers[an.user][an.index];
    }
    /*- My functions -*/
}
