# ChSwap DEX

A constant-product AMM built entirely by AI for a security hackathon. The jury runs automated audits to find vulnerabilities. Our goal: prove AI can produce safe, auditable smart contract code.

## What Makes This Different

ChSwap is **not a Uniswap V2 fork**. While it uses the proven x*y=k formula, it introduces 6 original innovations that address known V2 weaknesses:

| Innovation | What it does | V2 comparison |
|---|---|---|
| **Virtual Reserves** | First depositor gets full LP tokens. VIRTUAL_OFFSET=1000 prevents inflation attacks without burning tokens. | V2 burns MINIMUM_LIQUIDITY to address(0) |
| **Dynamic Fees** | 30-100 bps based on EMA/spot deviation. `max(preSwapFee, postSwapFee)` prevents fee manipulation. | V2 has fixed 0.3% |
| **Flash Loan Surcharge** | Flash swaps pay base fee + 9 bps. Borrowed liquidity costs more. | V2 charges same 0.3% |
| **EMA Oracle** | Per-block exponential moving average (5% alpha). Private vars with `nonReentrantView` getters. V2-compatible cumulative prices kept. | V2 only has arithmetic TWAP |
| **Per-Block Circuit Breaker** | First swap snapshots start-of-block reserves. All subsequent swaps compared against that baseline. Reverts if cumulative impact >10%. | V2 has no protection |
| **Timelock Governance** | 24h delay on admin changes via propose/execute/cancel. `feeToSetter` cannot be set to address(0). | V2 has instant admin |

## Architecture

```
ChFactory ──creates──> ChPair (one per token pair)
     |                    |
     |                    |-- ERC20 LP token (OpenZeppelin)
     |                    |-- ReentrancyGuard + nonReentrantView
     |                    |-- Dynamic fee engine (EMA-based)
     |                    |-- Per-block circuit breaker
     |                    +-- Flash swap with surcharge
     |
ChRouter ──────────────> User-facing interface
                         |-- Multi-hop swaps
                         |-- Slippage + deadline protection
                         |-- ETH wrapping (WETH)
                         |-- Fee-on-transfer token support
                         |-- minLiquidity sandwich protection
                         +-- removeLiquidityETHSupportingFeeOnTransferTokens
```

**Libraries:** ChLibrary (parameterized fee calculations), Math (sqrt, min), UQ112x112 (fixed-point for TWAP)

## Security Approach

- **Checks-Effects-Interactions** in every state-changing function
- **OpenZeppelin ReentrancyGuard** on all pair functions
- **`nonReentrantView`** on ALL price-sensitive views (getReserves, getSwapFee, emaPrice0/1)
- **`isLocked()`** public function for cross-contract composability safety
- **Safe transfer wrappers** handling non-standard ERC20s (USDT missing returns, fee-on-transfer)
- **All rounding favors the pool/LPs**, never the trader
- **Zero-value transfer guards** for tokens that revert on transfer(0)

## Testing

**137+ tests across 13 suites. 0 failures.**

```bash
forge test
```

| Suite | Tests | Coverage |
|---|---|---|
| ChFactory | 20 | Pair creation, full timelock governance |
| ChPair | 29 | Mint/burn, swaps, flash, oracle, dynamic fee, circuit breaker, fuzz |
| ChRouter | 21 | All swap variants, ETH, slippage, deadlines, multi-hop, FOT |
| SecurityAttacks | 11 | Reentrancy, flash underpay, first depositor, k fuzz, access control |
| FeeOnTransfer | 4 | Deflationary token support |
| LowDecimalTokens | 16 | 2/6/8/18 decimals, mixed pairs, round-trip profitability fuzz |
| Invariants | 6 | Single-actor, 16K+ random calls: k, solvency, supply, EMA, fees |
| MultiActorInvariant | 6 | 3-actor, 16K+ random calls: LP conservation, extraction bounds |
| CrossContract | 7 | Read-only reentrancy defense, mock lending protocol |
| EconomicAttacks | 8 | Monopoly LP, self-sandwich, EMA gaming, circuit breaker boundary |
| FormalVerification | 6 | amountOut < reserve, rounding direction, k preservation, round-trip |
| ForkTest | 6 | Mainnet fork with real USDC, USDT, WBTC, WETH |

### Key Properties Verified
- **k never decreases** -- fuzz (1000 runs) + invariant (16K calls) + formal
- **Round-trip swaps never profitable** -- fuzz across 2, 6, 18 decimal tokens
- **No value extraction** -- 3 independent actors, 16K random interactions
- **Fee always in [30, 100] bps** -- formally proven
- **Pair always solvent** -- balance >= reserves after any operation sequence

## Live Deployment (Sepolia Testnet)

| Contract | Address |
|---|---|
| **Factory** | [`0xc10753dB0CF87309Be84E57323A5C93E17c47040`](https://sepolia.etherscan.io/address/0xc10753dB0CF87309Be84E57323A5C93E17c47040) |
| **Router** | [`0x6e52D86960F2AfCBECb5531fad0d98506E64A35B`](https://sepolia.etherscan.io/address/0x6e52D86960F2AfCBECb5531fad0d98506E64A35B) |
| **WETH** | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` |

## Build and Test

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Build
forge build

# Test
forge test

# Fork test with real mainnet tokens (requires RPC URL)
forge test --match-contract ForkTest --fork-url $ETH_RPC_URL -vv

# Gas report
forge test --gas-report

# Deploy to testnet
WETH_ADDRESS=0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9 \
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --private-key $PRIVATE_KEY
```

## Project Structure

```
src/
  ChPair.sol            Core AMM (swap, mint, burn, flash, oracle, fees, circuit breaker)
  ChFactory.sol         Pair creation + timelock governance
  ChRouter.sol          User-facing router with all protections
  interfaces/           IChPair, IChFactory, IChCallee, IWETH
  libraries/            ChLibrary, Math, UQ112x112
test/                   13 test suites (unit, fuzz, invariant, economic, fork, formal)
script/
  Deploy.s.sol          Foundry deployment script
docs/
  WHITEPAPER.md         Technical design rationale
```

## Technology

- **Solidity** 0.8.28 (pinned, not floating)
- **Foundry** (Forge for testing, forge-std for assertions/cheatcodes)
- **OpenZeppelin** v5.6.1 (ERC20, ReentrancyGuard with nonReentrantView)
- **EVM target**: Cancun

## License

MIT
