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

### Defense Patterns
- **Checks-Effects-Interactions** in every state-changing function
- **OpenZeppelin ReentrancyGuard** on all pair functions
- **`nonReentrantView`** on ALL price-sensitive views (getReserves, getSwapFee, emaPrice0/1)
- **`isLocked()`** public function for cross-contract composability safety
- **Safe transfer wrappers** handling non-standard ERC20s (USDT missing returns, fee-on-transfer)
- **All rounding favors the pool/LPs**, never the trader
- **Zero-value transfer guards** in skim() for tokens that revert on transfer(0)

### Audit Trail

Three audit passes plus adversarial testing with the jury's own tool:

| Pass | Method | Findings | Fixed |
|---|---|---|---|
| **Pass 1** | Manual audit informed by 119-note web3 knowledge vault | 2 High, 4 Medium, 3 Low | All High + 1 Low fixed |
| **Pass 2** | Deep audit covering all 8 vault topic maps (~40 notes) | 2 Medium, 6 Low | Both Medium fixed |
| **Pass 3** | Grimoire adversarial audit (jury tool simulation) | 2 Medium, 4 Low, 3 Info | All fixed |
| **Static** | Slither (68 results, all false positives) + Aderyn | -- | -- |
| **Formal** | Halmos symbolic verification (fee bounds proven) | -- | -- |

Key findings discovered and fixed:
- Read-only reentrancy on view functions during flash swaps
- Dynamic fee self-lowering via pre-swap manipulation
- EMA compounding via sync() loop and multi-swap same-block attacks
- Circuit breaker bypass via swap splitting (now uses per-block baseline)
- Missing fee-on-transfer support in removeLiquidityETH

## Testing

**145 tests across 12 suites. 0 failures.**

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
| MultiActorInvariant | 6 | 3-actor, 16K+ random calls: same + LP conservation + extraction bounds |
| CrossContract | 7 | Read-only reentrancy defense, mock lending protocol, isLocked() |
| EconomicAttacks | 8 | Monopoly LP, self-sandwich, EMA gaming, circuit breaker boundary, flash surcharge |
| FormalVerification | 6 | amountOut < reserve, rounding direction, k preservation, round-trip, fee bounds |
| PoC (Grimoire) | 3+ | Proof-of-concept tests for fixed vulnerabilities |
| ForkTest | 6 | Mainnet fork with real USDC, USDT, WBTC, WETH. Multi-hop, remove liquidity. |

### Key Properties Verified
- **k never decreases** -- fuzz (1000 runs) + invariant (16K calls) + formal
- **Round-trip swaps never profitable** -- fuzz across 2, 6, 18 decimal tokens
- **No value extraction** -- 3 independent actors, 16K random interactions
- **Fee always in [30, 100] bps** -- Halmos formally proven
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

# Test (all unit, fuzz, invariant, economic, formal tests)
forge test

# Test with verbosity
forge test -vv

# Fork test with real mainnet tokens (requires RPC URL)
forge test --match-contract ForkTest --fork-url $ETH_RPC_URL -vv

# Gas report
forge test --gas-report

# Static analysis
slither . --filter-paths "lib/,test/"

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
test/
  ChPair.t.sol          Core pair tests + fuzz
  ChFactory.t.sol       Factory + governance tests
  ChRouter.t.sol        Router tests
  SecurityAttacks.t.sol Attack simulations
  Invariants.t.sol      Single-actor invariant tests
  MultiActorInvariant.t.sol  Multi-actor invariant tests
  EconomicAttacks.t.sol Game theory tests
  CrossContract.t.sol   Composability tests
  LowDecimalTokens.t.sol  Precision tests
  FormalVerification.t.sol  Property-based verification
  FeeOnTransfer.t.sol   FOT token tests
  ForkTest.t.sol        Mainnet fork with real tokens
  mocks/                MockERC20, WETH9, FeeOnTransferToken
script/
  Deploy.s.sol          Foundry deployment script (Factory + Router)
knowledge/              Web3 security knowledge vault (119+ notes, 8 topic maps)
docs/
  WHITEPAPER.md         Technical design rationale and threat model
```

## Technology

- **Solidity** 0.8.28 (pinned, not floating)
- **Foundry** (Forge for testing, forge-std for assertions/cheatcodes)
- **OpenZeppelin** v5.6.1 (ERC20, ReentrancyGuard with nonReentrantView)
- **EVM target**: Cancun (transient storage available)

## License

MIT
