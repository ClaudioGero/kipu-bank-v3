// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// OpenZeppelin imports
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// ============= UNISWAP V4 IMPORTS =============

/**
 * @title IUniversalRouter
 * @dev Interface for Uniswap V4 UniversalRouter
 * @notice Enables token swaps via Uniswap V4
 */
interface IUniversalRouter {
    /// @notice Execute one or multiple commands
    function execute(bytes calldata command, bytes[] calldata inputs) external payable;
    
    /// @notice Execute commands with deadline and refund to recipient
    function execute(bytes calldata command, bytes[] calldata inputs, uint256 deadline, address recipient) external payable;
}

/**
 * @title PoolKey
 * @dev Key for identifying a Uniswap V4 pool
 */
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/**
 * @notice Commands for Universal Router
 */
library Commands {
    uint8 constant V4_SWAP = 11;
}

/**
 * @notice Actions for V4 Router
 */
library Actions {
    uint8 constant SWAP_EXACT_IN_SINGLE = 0;
    uint8 constant SETTLE_ALL = 1;
    uint8 constant TAKE_ALL = 2;
}

/**
 * @notice V4 Router interface
 */
interface IV4Router {
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }
}

/**
 * @notice WETH9 interface
 */
interface IWETH9 {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

// ============= INTERFACES =============

/**
 * @title IAggregatorV3
 * @dev Chainlink Price Feed Interface
 * @notice Interface for Chainlink ETH/USD price feeds
 */
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    
    function description() external view returns (string memory);
    
    function version() external view returns (uint256);
    
    function getRoundData(uint80 _roundId)
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
    
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IERC20 {
    function totalSupply() external view returns (uint256);
    
    function balanceOf(address account) external view returns (uint256);
    
    function transfer(address to, uint256 amount) external returns (bool);
    
    function allowance(address owner, address spender) external view returns (uint256);
    
    function approve(address spender, uint256 amount) external returns (bool);
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

// ============= MAIN CONTRACT =============

/**
 * @title KipuBankV2
 * @dev Advanced multi-token vault system with USD limits and admin recovery
 * @notice Enhanced version of KipuBank with Chainlink oracle integration
 * @author Senior Solidity Engineer
 */
contract KipuBankV2 is AccessControl, ReentrancyGuard {
    
    // ============= TYPES =============
    
    /// @notice Enum for token types supported by the vault
    enum TokenType {
        NATIVE,  // ETH
        ERC20    // ERC-20 tokens
    }
    
    /// @notice Struct containing token information
    struct TokenInfo {
        TokenType tokenType;    // Type of token
        uint8 decimals;        // Token decimals
        bool isSupported;      // Whether token is supported
        uint256 minDeposit;    // Minimum deposit amount
        uint256 maxDeposit;    // Maximum deposit amount
    }
    
    /// @notice Struct for user balance information
    struct UserBalance {
        uint256 nativeBalance;                    // ETH balance
        mapping(address => uint256) tokenBalances; // ERC-20 token balances
    }
    
    // ============= CONSTANTS =============
    
    /// @notice Chainlink price feed decimals (always 8)
    uint8 public constant PRICE_FEED_DECIMALS = 8;
    
    /// @notice ETH decimals (always 18)
    uint8 public constant ETH_DECIMALS = 18;
    
    /// @notice USD decimals (6 for USDC standard)
    uint8 public constant USD_DECIMALS = 6;
    
    /// @notice Scale factors for calculations
    uint256 public constant ETH_SCALE = 10**ETH_DECIMALS;
    uint256 public constant USD_SCALE = 10**USD_DECIMALS;
    uint256 public constant PRICE_SCALE = 10**PRICE_FEED_DECIMALS;
    
    /// @notice Chainlink ETH/USD Price Feed (Sepolia)
    address public constant ETH_USD_PRICE_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
    
    /// @notice USDC token address (Sepolia)
    address public constant USDC_SEPOLIA = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
    
    /// @notice Uniswap V4 UniversalRouter (Sepolia)
    address public constant UNISWAP_V4_ROUTER = 0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b;
    
    /// @notice WETH9 address (Sepolia)
    address public constant WETH_SEPOLIA = 0xfff9976782d46cc05630d1f6ebab18b2324d6b14;
    
    /// @notice Maximum slippage tolerance (3%)
    uint256 public constant MAX_SLIPPAGE = 3;
    
    // ============= ROLES =============
    
    /// @notice Admin role for contract management
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Operator role for daily operations
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    // ============= STATE VARIABLES =============
    
    /// @notice Chainlink ETH/USD price feed
    /// @dev Set at deployment, immutable for security
    IAggregatorV3 public immutable ethUsdPriceFeed;
    
    /// @notice Maximum bank capacity in USD
    /// @dev Set at deployment, prevents unlimited deposits
    uint256 public maxBankCapUSD;
    
    /// @notice Maximum withdrawal limit in USD
    /// @dev Set at deployment, prevents large withdrawals
    uint256 public maxWithdrawalUSD;
    
    /// @notice Current total deposits in USD
    /// @dev Increases on deposits, decreases on withdrawals
    uint256 public totalDepositedUSD;
    
    /// @notice Total number of deposits made
    /// @dev Incremented on each successful deposit
    uint256 public depositCount;
    
    /// @notice Total number of withdrawals made
    /// @dev Incremented on each successful withdrawal
    uint256 public withdrawalCount;
    
    /// @notice USDC token address (from constant)
    address public immutable USDC_ADDRESS;
    
    /// @notice Uniswap V4 UniversalRouter (from constant)
    IUniversalRouter public immutable router;
    
    // ============= MAPPINGS =============
    
    /// @notice Maps user address to their balance information
    /// @dev Contains both native ETH and ERC-20 token balances
    mapping(address => UserBalance) public userBalances;
    
    /// @notice Maps token address to token information
    /// @dev Used to track supported tokens and their properties
    mapping(address => TokenInfo) public supportedTokens;
    
    /// @notice Maps token address to Chainlink price feed (for ETH price only)
    mapping(address => IAggregatorV3) public tokenPriceFeeds;
    
    
    // ============= CUSTOM ERRORS =============
    
    error InsufficientBalance();
    error ExceedsWithdrawalLimit();
    error BankCapExceeded();
    error TransferFailed();
    error DepositTooSmall();
    error ZeroAmount();
    error TokenNotSupported(address token);
    error TokenNotTradable(address token);
    error InsufficientOutput(uint256 expected, uint256 actual);
    error SwapFailed(address token, uint256 amount);
    error PoolNotFound(address token);
    error UnauthorizedAccess();
    
    // ============= EVENTS =============
    
    event DepositMade(address indexed user, uint256 amount, uint256 newBalance);
    event WithdrawalMade(address indexed user, uint256 amount, uint256 newBalance);
    event TokenAdded(address indexed token, TokenInfo info);
    event MultiTokenDeposit(address indexed user, address indexed token, uint256 amount, uint256 usdValue);
    event MultiTokenWithdrawal(address indexed user, address indexed token, uint256 amount, uint256 usdValue);
    
    // Uniswap V4 swap events
    event SwapExecuted(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcOut);
    event USDCWithdrawal(address indexed user, uint256 amount);
    
    // ============= MODIFIERS =============
    
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert UnauthorizedAccess();
        _;
    }
    
    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, msg.sender) && !hasRole(ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedAccess();
        }
        _;
    }
    
    modifier validToken(address token) {
        if (!supportedTokens[token].isSupported) revert TokenNotSupported(token);
        _;
    }
    
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }
    
    // ============= CONSTRUCTOR =============
    
    /// @notice Constructor with bank cap and withdrawal limit
    constructor(
        uint256 _maxBankCapUSD,
        uint256 _maxWithdrawalUSD
    ) {
        ethUsdPriceFeed = IAggregatorV3(ETH_USD_PRICE_FEED);
        USDC_ADDRESS = USDC_SEPOLIA;
        router = IUniversalRouter(UNISWAP_V4_ROUTER);
        
        maxBankCapUSD = _maxBankCapUSD;
        maxWithdrawalUSD = _maxWithdrawalUSD;
        
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        
        supportedTokens[address(0)] = TokenInfo({
            tokenType: TokenType.NATIVE,
            decimals: ETH_DECIMALS,
            isSupported: true,
            minDeposit: 0,
            maxDeposit: type(uint256).max
        });
        
        emit TokenAdded(address(0), supportedTokens[address(0)]);
    }
    
    // ============= INTERNAL FUNCTIONS =============
    
    /// @notice Validates if ERC-20 token is supported
    function _validateERC20Token(address token) internal view {
        if (token == address(0)) revert TokenNotSupported(token);
        if (!supportedTokens[token].isSupported) revert TokenNotSupported(token);
    }
    
    // ============= CONVERSION FUNCTIONS =============
    
    /// @notice Converts ETH amount to USD using Chainlink price feed
    function _convertETHToUSD(uint256 ethAmount) internal view returns (uint256) {
        uint256 ethPrice = getCurrentETHPrice(); // 8 decimals
        return (ethAmount * ethPrice) / ETH_SCALE; // divide by 1e18 to normalize wei
    }
    
    /// @notice Converts ERC-20 token amount to USD via ETH conversion
    function _convertERC20ToUSD(address token, uint256 tokenAmount) internal view returns (uint256) {
        TokenInfo memory tokenInfo = supportedTokens[token];
        uint256 normalizedAmount = normalizeDecimals(tokenAmount, tokenInfo.decimals, ETH_DECIMALS);
        return _convertETHToUSD(normalizedAmount);
    }
    
    /// @notice Normalizes token amounts between different decimal places
    function normalizeDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) public pure returns (uint256) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals < toDecimals) {
            return amount * (10 ** (toDecimals - fromDecimals));
        } else {
            return amount / (10 ** (fromDecimals - toDecimals));
        }
    }
    
    // ============= UNISWAP V4 SWAP FUNCTIONS =============
    
    /// @notice Preview expected USDC output from token swap
    /// @param token Token address to swap
    /// @param amount Amount of token to swap
    /// @return preview USDC output estimation
    function _getUSDCOutput(address token, uint256 amount) internal view returns (uint256) {
        if (token == USDC_ADDRESS) {
            return amount;
        }
        
        // For ETH/WETH, use Chainlink oracle
        if (token == address(0)) {
            uint256 ethPrice = getCurrentETHPrice();
            return (amount * ethPrice) / ETH_SCALE;
        }
        
        // For other tokens, return conservative estimate
        // In production, this would query the Uniswap pool
        uint8 decimals = supportedTokens[token].decimals;
        return normalizeDecimals(amount, decimals, USD_DECIMALS);
    }
    
    /// @notice Execute swap from any token to USDC via Uniswap V4
    /// @param token Input token address (or address(0) for ETH)
    /// @param amount Input token amount
    /// @return usdcAmount Actual USDC amount received
    function _swapTokenForUSDC(address token, uint256 amount) internal returns (uint256) {
        if (token == USDC_ADDRESS) {
            return amount;
        }
        
        // Wrap ETH to WETH if needed
        if (token == address(0)) {
            IWETH9(WETH_SEPOLIA).deposit{value: amount}();
            token = WETH_SEPOLIA;
        }
        
        // Approve router to spend tokens
        IERC20(token).approve(address(router), amount);
        
        // Calculate minimum output with slippage protection
        uint256 expectedOutput = _getUSDCOutput(token == WETH_SEPOLIA ? address(0) : token, amount);
        uint128 minAmountOut = uint128(expectedOutput - (expectedOutput * MAX_SLIPPAGE / 100));
        
        // Prepare pool key (sorted addresses)
        PoolKey memory poolKey = PoolKey({
            currency0: token < USDC_ADDRESS ? token : USDC_ADDRESS,
            currency1: token < USDC_ADDRESS ? USDC_ADDRESS : token,
            fee: 500,
            tickSpacing: 10,
            hooks: address(0)
        });
        
        bool zeroForOne = token < USDC_ADDRESS;
        
        // Encode Universal Router command
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        
        // Encode actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
        
        // Encode parameters
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(IV4Router.ExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: zeroForOne,
            amountIn: uint128(amount),
            amountOutMinimum: minAmountOut,
            hookData: bytes("")
        }));
        params[1] = abi.encode(token, amount);
        params[2] = abi.encode(USDC_ADDRESS, minAmountOut);
        
        inputs[0] = abi.encode(actions, params);
        
        // Execute swap
        uint256 balanceBefore = IERC20(USDC_ADDRESS).balanceOf(address(this));
        router.execute(commands, inputs);
        
        uint256 balanceAfter = IERC20(USDC_ADDRESS).balanceOf(address(this));
        uint256 usdcAmount = balanceAfter - balanceBefore;
        
        if (usdcAmount < minAmountOut) {
            revert InsufficientOutput(minAmountOut, usdcAmount);
        }
        
        return usdcAmount;
    }
    
    // ============= DEPOSIT FUNCTIONS =============
    
    /// @notice Deposits native ETH into user's vault
    /// @dev ETH is swapped to USDC via Uniswap V4 and credited to user
    function depositETH() external payable nonReentrant validAmount(msg.value) {
        _processDeposit(address(0), msg.value);
    }
    
    /// @notice Deposits ERC-20 tokens into user's vault
    /// @dev Token is swapped to USDC via Uniswap V4 and credited to user
    /// @dev Accepts any ERC20 token supported by Uniswap V4
    function depositToken(address token, uint256 amount) external nonReentrant validAmount(amount) {
        require(token != address(0), "Invalid token");
        
        // Transfer token to contract
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        
        _processDeposit(token, amount);
    }
    
    /// @notice Internal function to process deposits and update balances
    function _processDeposit(address token, uint256 amount) internal {
        uint256 usdcAmount;
        
        // Fast path: USDC direct deposit
        if (token == USDC_ADDRESS) {
            usdcAmount = amount;
        } 
        // ETH deposit: ETH is already received, will be swapped to USDC
        else if (token == address(0)) {
            // Preview expected USDC output from ETH
            uint256 previewOutput = _getUSDCOutput(token, amount);
            
            // Check bank cap with preview
            if (totalDepositedUSD + previewOutput > maxBankCapUSD) {
                revert BankCapExceeded();
            }
            
            // Execute swap ETH to USDC
            usdcAmount = _swapTokenForUSDC(token, amount);
            
            // Emit swap event
            emit SwapExecuted(msg.sender, token, amount, usdcAmount);
        }
        // Swap path: Convert token to USDC
        else {
            // Preview expected USDC output
            uint256 previewOutput = _getUSDCOutput(token, amount);
            
            // Check bank cap with preview
            if (totalDepositedUSD + previewOutput > maxBankCapUSD) {
                revert BankCapExceeded();
            }
            
            // Execute swap to USDC
            usdcAmount = _swapTokenForUSDC(token, amount);
            
            // Emit swap event
            emit SwapExecuted(msg.sender, token, amount, usdcAmount);
        }
        
        // Check bank cap with actual USDC amount
        if (totalDepositedUSD + usdcAmount > maxBankCapUSD) {
            revert BankCapExceeded();
        }
        
        // Credit USDC balance to user
        userBalances[msg.sender].tokenBalances[USDC_ADDRESS] += usdcAmount;
        
        totalDepositedUSD += usdcAmount;
        depositCount++;
        
        emit MultiTokenDeposit(msg.sender, token, amount, usdcAmount);
    }
    
    // ============= WITHDRAWAL FUNCTIONS =============
    
    /// @notice Withdraws USDC from user's vault
    /// @dev Users withdraw USDC since all deposits are converted to USDC
    function withdrawUSDC(uint256 amount) external nonReentrant validAmount(amount) {
        _processWithdrawal(amount);
    }
    
    /// @notice Withdraws USDC from user's vault
    /// @dev Users withdraw USDC since all deposits are converted to USDC
    /// @param amount Amount of USDC to withdraw
    function withdrawToken(uint256 amount) external nonReentrant validAmount(amount) {
        _processWithdrawal(amount);
    }
    
    /// @notice Internal function to process withdrawals and update balances
    /// @dev Users withdraw USDC only (since all balances are in USDC)
    function _processWithdrawal(uint256 amount) internal {
        // Users can only withdraw USDC
        uint256 usdcAmount = amount;
        
        // Check withdrawal limit
        if (usdcAmount > maxWithdrawalUSD) {
            revert ExceedsWithdrawalLimit();
        }
        
        // Validate USDC balance
        if (usdcAmount > userBalances[msg.sender].tokenBalances[USDC_ADDRESS]) {
            revert InsufficientBalance();
        }
        
        // Update balances
        userBalances[msg.sender].tokenBalances[USDC_ADDRESS] -= usdcAmount;
        totalDepositedUSD -= usdcAmount;
        withdrawalCount++;
        
        // Transfer USDC to user
        IERC20(USDC_ADDRESS).transfer(msg.sender, usdcAmount);
        
        emit MultiTokenWithdrawal(msg.sender, USDC_ADDRESS, usdcAmount, usdcAmount);
        emit USDCWithdrawal(msg.sender, usdcAmount);
    }
    
    // ============= VIEW FUNCTIONS =============
    
    /// @notice Gets user's balance for a specific token
    function getUserBalance(address user, address token) external view returns (uint256) {
        if (token == address(0)) {
            return userBalances[user].nativeBalance;
        } else {
            return userBalances[user].tokenBalances[token];
        }
    }
    
    /// @notice Gets current ETH/USD price from Chainlink oracle
    function getCurrentETHPrice() public view returns (uint256) {
        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = ethUsdPriceFeed.latestRoundData();
        
        if (price <= 0) revert TransferFailed();
        if (roundId == 0 || answeredInRound < roundId) revert TransferFailed();
        if (block.timestamp - updatedAt > 3600) revert TransferFailed(); // Stale > 1 hour
        
        return uint256(price);
    }
    
    /// @notice Converts any token amount to USD equivalent in USDC terms
    function convertToUSD(address token, uint256 amount) public view returns (uint256) {
        // USDC direct: 1:1
        if (token == USDC_ADDRESS) {
            return amount;
        }
        // ETH: Use Chainlink oracle for reference
        else if (token == address(0)) {
            return _convertETHToUSD(amount);
        }
        // Other tokens: Preview swap output
        else {
            return _getUSDCOutput(token, amount);
        }
    }
    
    // ============= RECEIVE/FALLBACK =============
    
    /// @notice Prevents direct ETH transfers to contract
    receive() external payable {
        revert ZeroAmount();
    }
    
    /// @notice Prevents calls to non-existent functions
    fallback() external payable {
        revert ZeroAmount();
    }
    
}