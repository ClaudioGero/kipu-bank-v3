# **KipuBankV3 – USDC-Capped Vault with Uniswap v4 Swaps**

## **Project Description**
**KipuBankV3** is an evolution of V2: a smart-contract vault that **accepts ETH and arbitrary ERC-20 tokens**, **converts deposits to USDC via Uniswap v4’s Universal Router**, and **enforces a global bank cap** and **per-withdrawal limit**. It keeps the role-based admin model, telemetry events, and custom errors introduced in V2.

---

## **Main Features**

### **Core Functionality**
- **Generalized Deposits:** Users can deposit **ETH (native)** or **any ERC-20**; non-USDC assets are **swapped on-chain to USDC** via Uniswap v4.
- **USDC-Aware Limits:** Accounting is in **USDC (6 decimals)**. Deposits and withdrawals are checked against **global bank cap** and **per-withdrawal maximum**.
- **Per-User Balances:** Internal ledger credits users **in USDC** after swaps; USDC is the unit of account for the vault.

### **Operations & Admin**
- **Access Control (RBAC):**
  - ***DEFAULT_ADMIN_ROLE*** — super admin.
  - ***ADMIN_ROLE*** — maintenance tasks.
  - ***OPERATOR_ROLE*** — day-to-day ops (optional use).
- **Event-Rich Telemetry:** Deposits, withdrawals and swaps emit typed events (amount in, USDC out, etc.).
- **Custom Errors:** Gas-efficient reverts for common failure cases (e.g., ***BankCapExceeded***, ***InsufficientOutput***).

---

## **Technical Implementation (V3)**

### **Architecture Overview**
- **On-chain Swaps:** Integrates **Uniswap v4 Universal Router** to route **ETH/any ERC-20 → USDC** inside the contract.
- **Price Oracle (ETH only):** Uses **Chainlink ETH/USD** (8 decimals) for reference in previews and guards (same interface from V2).
- **USDC Accounting:** **USDC** (6 decimals) is treated as “USD” in state variables like `totalDepositedUSD`.

### **Decimals & Scales**
- **ETH:** 18 decimals  
- **USDC:** 6 decimals  
- **ETH/USD Price:** 8 decimals (Chainlink)  
- Helpers normalize values (e.g., ETH-denominated amounts → USDC scale) for previews; actual deposits credit **USDC received** from swap.

### **Roles Bootstrap**
- The constructor grants:
  - `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE`, `OPERATOR_ROLE` to the **deployer** (OpenZeppelin AccessControl + ReentrancyGuard).

### **Token Handling**
- **ETH:** Accepted via `depositETH()`. Wrapped to **WETH** internally when needed for swap routing.
- **ERC-20:** Accepted via `depositToken(token, amount)`. Contract pulls tokens first, then swaps to **USDC**.
- **USDC (direct):** If the token is already USDC, the contract **skips swapping** and credits directly.

### **Key Data Structures**
```solidity
enum TokenType { NATIVE, ERC20 }

struct TokenInfo {
    TokenType tokenType;
    uint8     decimals;
    bool      isSupported;      // used for native pre-registration; ERC-20 path generalized in V3
    uint256   minDeposit;
    uint256   maxDeposit;
}

struct UserBalance {
    uint256 nativeBalance;      // kept for backward-compat getters
    mapping(address => uint256) tokenBalances; // USDC is the unit credited in V3
}
```
- **Mappings**
  - `mapping(address => UserBalance) userBalances;`
  - `mapping(address => TokenInfo) supportedTokens;` *(ETH pre-registered; ERC-20 path generalized)*
  - `mapping(address => IAggregatorV3) tokenPriceFeeds;` *(ETH feed effective)*

---

## **Core Flows**

### **Deposits**
1. **ETH:**  
   - `depositETH()` receives `msg.value`.  
   - Internal preview (conservative) checks cap.  
   - Swaps ETH→USDC via **Universal Router**.  
   - Credits **USDC** to caller, updates `totalDepositedUSD`, emits `SwapExecuted` and `MultiTokenDeposit`.

2. **ERC-20:**  
   - `depositToken(token, amount)` does `transferFrom()` to the contract.  
   - Preview check vs cap.  
   - Swaps `token→USDC` (unless already USDC).  
   - Credits **USDC** and emits events.

> **Note:** Cap checks consider **USDC units**. Final credit uses **actual USDC received**.

### **Withdrawals**
- **USDC-only:**  
  - `withdrawUSDC(amount)` (alias `withdrawToken(amount)` in this version)  
  - Enforces `maxWithdrawalUSD` (USDC 6d), debits user’s USDC balance, transfers USDC, updates accounting, emits `MultiTokenWithdrawal` and `USDCWithdrawal`.

---

## **Errors & Events (highlights)**

### **Custom Errors**
- ***BankCapExceeded()***
- ***InsufficientBalance()***
- ***ExceedsWithdrawalLimit()***
- ***InsufficientOutput(expected, actual)***
- ***TokenNotSupported(address)***
- ***UnauthorizedAccess()***
- ***TransferFailed()***, ***ZeroAmount()***, ***SwapFailed(token, amount)***

### **Events**
- ***TokenAdded(token, info)***
- ***MultiTokenDeposit(user, tokenIn, amountIn, usdcCredited)***
- ***MultiTokenWithdrawal(user, token, amount, usdValue)***
- ***SwapExecuted(user, tokenIn, amountIn, usdcOut)***
- ***USDCWithdrawal(user, amount)***

---

## **Contract Components**

### **Immutable/Constant Addresses (Sepolia)**
- **Chainlink ETH/USD (Sepolia):** `0x694AA1769357215DE4FAC081bf1f309aDC325306`  
- **USDC (Sepolia):** `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`  
- **Universal Router v4 (Sepolia):** `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b`  
- **WETH9 (Sepolia):** `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`


### **Storage Variables**
- `uint256 public maxBankCapUSD;` *(USDC, 6d)*  
- `uint256 public maxWithdrawalUSD;` *(USDC, 6d)*  
- `uint256 public totalDepositedUSD;` *(USDC, 6d)*  
- `uint256 public depositCount;` / `withdrawalCount;`

### **Public Views**
- `getUserBalance(user, token)` — per-asset ledger view (USDC credited in V3).  
- `convertToUSD(token, amount)` — helper preview; **USDC 1:1**; ETH preview via Chainlink; other tokens use conservative normalization.  
- `getCurrentETHPrice()` — Chainlink latest round guards (non-stale, positive).

---

## **Prerequisites**
- Wallet (MetaMask or similar) connected to **Sepolia**
- **USDC (Sepolia)** and test tokens you plan to deposit/swap
- Remix / Foundry / Hardhat to deploy and interact

---

## **Deployment Instructions**

### **Step 1: Setup**
- Create `contracts/KipuBankV3.sol` and paste the contract source.
- Compiler: **Solidity ^0.8.19** (or `0.8.30`), **Optimizer ON** (200–999 runs).

### **Step 2: Constructor Arguments (USDC 6d)**
- **Bank Cap:** *1,000,000 USDC* → `1_000_000 * 1e6 = 1_000_000_000_000`  
- **Max Withdrawal:** *25,000 USDC* → `25_000 * 1e6 = 25_000_000_000`

### **Step 3: Deploy**
- Network: **Sepolia**
- Confirm the transaction and keep the deployed address.

### **Step 4: Verify**
- On the explorer (e.g., Etherscan Sepolia): **Verify & Publish**  
- Match compiler version + optimizer settings  
- Include all interfaces used by the contract file.

---

## **How to Interact with the Contract**

### **Depositing**
- **ETH:**  
  - In Remix, set **VALUE** (e.g., `0.1 ether`) and call `depositETH()`.
- **ERC-20:**  
  - First `approve` the **contract** to spend your tokens.  
  - Call `depositToken(<token>, <amount>)`.  
  - The contract swaps to **USDC** and credits your balance.

### **Withdrawing**
- **USDC only:**  
  - Call `withdrawUSDC(<amount>)` (or `withdrawToken(<amount>)` in this version).  
  - Enforced by `maxWithdrawalUSD`.

### **Reading State**
- `getUserBalance(<yourAddress>, <USDC_ADDRESS>)` → **your USDC balance**.  
- `totalDepositedUSD()` → total USDC inside the bank.  
- `maxBankCapUSD()` and `maxWithdrawalUSD()` → risk limits.

---

## **Deployed Contracts**
- **KipuBankV3 (latest on Sepolia):** _add here after deployment_  
- (Legacy) **KipuBankV2:** `0x5b718aa6cA0c8F94D5275269A5d38C049B9b1c4D`

---

## **Notes & Design Considerations**
- ***USDC as Unit of Account:*** V3 focuses accounting on **USDC (6d)** for clarity and deterministic limits.  
- ***Previews vs Actuals:*** Previews are conservative; **final credit uses actual USDC received from the swap**.  
- ***Security:*** Non-reentrant deposit/withdraw paths; guarded Chainlink reads; revert-on-failure semantics via custom errors.  
- ***Extensibility:*** Router addresses are network-scoped; consider constructor-param wiring if you plan multi-network deployments.
