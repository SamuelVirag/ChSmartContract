# ChSmartContract - DEX Hackathon

## Project Context
Building a DEX (Decentralized Exchange) smart contract for a hackathon. The jury will run security audits (V12.sh and Grimoire) to find vulnerabilities. Our goal: prove AI can produce safe, auditable smart contract code.

## Architecture
Constant-product AMM (x*y=k) with 6 original innovations that differentiate from Uniswap V2:

| Feature | Description |
|---|---|
| **Virtual reserves** | First-depositor protection via VIRTUAL_OFFSET=1000. No LP tokens burned — first depositor gets full `sqrt(a0*a1)`. |
| **Dynamic fees** | 30-100 bps based on spot/EMA deviation. Uses `max(preSwapFee, postSwapFee)` to prevent fee manipulation. |
| **Flash loan surcharge** | Flash swaps pay base fee + 9 bps extra. |
| **EMA oracle** | Per-block exponential moving average (5% alpha, gated by timestamp). Alongside V2-compatible cumulative prices. Private vars with `nonReentrantView` getters. |
| **Circuit breaker** | Per-block baseline: compares all swaps against start-of-block reserves. Reverts if cumulative impact >10%. Ceiling division for strict enforcement. |
| **Timelock governance** | 24h delay on admin changes via propose/execute/cancel pattern. |

### Contracts
- **ChPair.sol** — Core AMM: swap, mint/burn LP, flash swaps, EMA oracle, dynamic fees, circuit breaker
- **ChFactory.sol** — Pair creation via CREATE2, timelock governance
- **ChRouter.sol** — User-facing: multi-hop, slippage/deadline, ETH wrapping, fee-on-transfer support, `minLiquidity` sandwich protection
- **ChLibrary.sol** — Quote/amount calculations with parameterized fees
- **Math.sol** — sqrt, min
- **UQ112x112.sol** — Fixed-point math for TWAP oracle

### Key Security Patterns
- OpenZeppelin ReentrancyGuard (with `nonReentrantView` on `getReserves()`)
- Public `isLocked()` for cross-contract composability (read-only reentrancy defense)
- `nonReentrantView` on ALL price-sensitive views (`getReserves`, `getSwapFee`, `emaPrice0`, `emaPrice1`)
- CEI pattern throughout
- Safe transfer wrappers for non-standard ERC20s (USDT, missing return values)
- All rounding favors pool/LPs, never the trader
- `getAmountIn` rounds up (+1), `getAmountOut` rounds down
- Zero-value transfer guards in `skim()`
- `feeToSetter` cannot be set to address(0)

## Web3 Knowledge Vault
A full Ars Contexta vault lives at `./knowledge/` with its own git repo and QMD collection.

- **Location**: `./knowledge/` (full Ars Contexta structure)
- **QMD collection**: `web3` — use `mcp__qmd__deep_search` with `collection: "web3"` to search
- **Content**: 119 notes across 8 sub-topic maps (reentrancy, access control, oracle security, MEV, precision math, ERC20 edge cases, Solidity footguns, audit methodology)
- **To use skills**: Start a Claude session from `./knowledge/` directory — `/learn`, `/extract`, `/connect` etc. all work as normal

Do NOT use the `knowledge` QMD collection for web3 topics — keep domains separated.

## Custom Skills
- `/audit [contract-path]` — Security audit checklist informed by web3 vault knowledge

## Testing
Foundry with Solidity 0.8.28, `via_ir = true`, optimizer 200 runs.

**145+ tests across 13 suites** (plus 6 mainnet fork tests):
- **ChFactory.t.sol** (20) — Pair creation, full timelock governance flows
- **ChPair.t.sol** (29) — Mint/burn, swaps, flash swaps, oracle, dynamic fee, circuit breaker, protocol fee, fuzz
- **ChRouter.t.sol** (21) — All swap variants, ETH, slippage, deadlines, multi-hop, fee-on-transfer
- **SecurityAttacks.t.sol** (11) — Reentrancy (2 variants), flash underpay, first depositor, k fuzz, access control, oracle/EMA manipulation, circuit breaker
- **FeeOnTransfer.t.sol** (4) — Deflationary token support
- **LowDecimalTokens.t.sol** (16) — 2/6/8/18 decimal pairs, mixed decimals, round-trip profitability fuzz (3 campaigns), LP precision
- **Invariants.t.sol** (6) — Single-actor: k never decreases, reserves match balances, supply consistency, EMA positive, fee bounds, solvency (16K+ random calls each)
- **MultiActorInvariant.t.sol** (6) — 3-actor: same invariants + LP conservation + no global extraction (16K+ random calls each)
- **CrossContract.t.sol** (7) — Read-only reentrancy defense: `nonReentrantView` on getReserves/getSwapFee, `isLocked()`, mock lending protocol protection
- **EconomicAttacks.t.sol** (8) — Monopoly LP extraction bounds, self-sandwich unprofitability, EMA gaming resistance, circuit breaker boundary, flash surcharge circumvention
- **FormalVerification.t.sol** (6) — Properties: amountOut < reserve, rounding direction (floor/ceil), k preservation, round-trip unprofitability, fee bounds (Halmos verified)
- **PoC_MissingRemoveLiquidityEthFoT.t.sol** (3) — Verifies `removeLiquidityETHSupportingFeeOnTransferTokens` works correctly
- **ForkTest.t.sol** (6) — Mainnet fork: real USDC (6 dec), USDT (missing returns), WBTC (8 dec), WETH. Multi-hop, remove liquidity, dynamic fee. Run with `--fork-url`

## Audit History

### Pass 1 — Quick Audit
| ID | Severity | Finding | Status |
|---|---|---|---|
| H-1 | High | `getReserves()` exposed stale state during flash swaps (read-only reentrancy) | **FIXED** — added `nonReentrantView`, exposed `isLocked()` |
| H-2 | High | Dynamic fee used pre-swap reserves — attacker could self-lower fees | **FIXED** — now uses `max(preSwapFee, postSwapFee)` |
| M-1 | Medium | Virtual offset asymmetry between first mint and burn (hidden first-deposit cost) | Accepted — documented in NatSpec |
| M-2 | Medium | Permissionless pair creation enables spam | Accepted — standard DEX design |
| M-3 | Medium | Circuit breaker bypassable via multi-hop routing | Accepted — inherent per-pair limitation |
| M-4 | Medium | EMA oracle can initialize to manipulated price | Accepted — converges after ~20 trades |
| L-1 | Low | No emergency pause on Pair | Accepted — permissionless core by design |
| L-2 | Low | `skim()` permissionless | By design, matches V2 |
| L-3 | Low | `feeToSetter` could be set to address(0), permanently locking governance | **FIXED** — added zero-address check |

### Pass 2 — Deep Audit (all 8 vault topic maps, ~40 notes read)
| ID | Severity | Finding | Status |
|---|---|---|---|
| M-5 | Medium | No `minLiquidity` parameter — LP deposit sandwich attack possible | **FIXED** — added `minLiquidity` param to `addLiquidity`/`addLiquidityETH` |
| M-6 | Medium | `skim()` zero-value transfer reverts with tokens like LEND | **FIXED** — added `if (excess > 0)` guard |
| L-4 | Low | No EIP-2612 permit on LP token (avoids V2's DOMAIN_SEPARATOR replay bug) | Accepted |
| L-5 | Low | ERC777 callbacks could enable cross-contract reentrancy | Mitigated by `isLocked()` + `nonReentrantView` |
| L-6 | Low | uint112 reserve overflow with extreme-decimal tokens | Runtime revert in `_update()`, not exploitable |
| L-7 | Low | Low-decimal tokens (2 decimals) have larger rounding magnitude | Rounding direction correct, just larger per-unit |
| L-8 | Low | Selfdestruct can force ETH into pair | No impact — uses tracked reserves, not `address(this).balance` |
| L-9 | Low | `block.timestamp` manipulable by ~15 seconds | Minimal impact on deadlines and oracle |
| — | — | `factory` state variable should be immutable | **FIXED** |

### Pass 3 — Grimoire Adversarial Audit (jury tool simulation)
Ran Grimoire plugin with `summon` against the codebase. 9 sigil findings produced, 1 dismissed.

| Finding | Severity | Description | Status |
|---|---|---|---|
| sync-loop-ema-fee-gaming | Low | Repeated `sync()` compounds EMA shift at zero cost | **FIXED** — EMA now per-block gated (`timeElapsed > 0`) |
| ema-multi-swap-compounding | Medium | EMA updates per-swap not per-block, enabling same-block compounding | **FIXED** — same per-block gating fix |
| circuit-breaker-swap-splitting | Medium | N sequential swaps on single pair bypass circuit breaker | **FIXED** — per-block baseline: first swap snapshots start-of-block reserves |
| read-only-reentrancy-unguarded-views | Low | `getSwapFee()` and EMA vars readable with stale state during flash | **FIXED** — `nonReentrantView` on `getSwapFee()`; EMA vars made private with guarded getters |
| stale-fee-fot-swap-revert | Low | FOT router queries stale fee causing unnecessary reverts | **FIXED** — FOT swap path now uses `MAX_FEE_BPS` (100) conservatively |
| missing-remove-liquidity-eth-fee-on-transfer | Low | No `removeLiquidityETHSupportingFeeOnTransferTokens` | **FIXED** — function added to Router |
| min-fee-bps-dead-code | Info | `MIN_FEE_BPS` (10) unreachable, actual min is `BASE_FEE_BPS` (30) | **FIXED** — removed `MIN_FEE_BPS`, documented `BASE_FEE_BPS` as minimum |
| circuit-breaker-rounding-permissiveness | Info | Deviation rounds down, allows ~10.01% | **FIXED** — changed to ceiling division |
| first-depositor-inflation-mitigated | Info | Virtual offset mechanism confirmed effective | No action needed |
| *(dismissed)* ema-readable-during-flash-callback | — | Duplicate of unguarded-views finding | Dismissed by Grimoire familiar |

### Static Analysis
- **Slither**: 68 results, all false positives or already-known issues. No new real findings.
- **Gas profiling**: swap ~108K, mint ~131K — reasonable, no DoS risk.
- **Halmos symbolic verification**: Fee bounds property formally proven. Complex math properties pass 1000+ fuzz runs.

### Jury Tools Research
- **V12.sh**: Black-box AI auditor, opaque methodology. Can't predict specific checks.
- **Grimoire**: Open-source Claude plugin. Ran full audit — 4 genuinely new issues found and fixed. All sigil findings now resolved.
- **dapp.org V2 audit**: Cross-referenced all 3 findings. Fee-on-transfer (fixed), liquidity deflation (fixed via virtual reserves), sqrt overflow (fixed in our Math.sol).

### Mainnet Fork Validation
Deployed on Ethereum mainnet fork (block 24719681) and tested with real tokens:
- **USDC** (6 decimals): liquidity + swap working correctly
- **USDT** (missing return values): safe transfer wrappers handle correctly
- **WBTC** (8 decimals): low-decimal precision verified
- **Multi-hop**: WBTC → WETH → USDC across mixed-decimal pairs
- All 6 fork tests passing

### Testnet Deployment (Sepolia)
- **Factory**: `0xc10753dB0CF87309Be84E57323A5C93E17c47040`
- **Router**: `0x6e52D86960F2AfCBECb5531fad0d98506E64A35B`
- **WETH**: `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9`
- **Admin**: `0xfEB8Ed0a4f6742dE2880E9D9e6C91f87B050FfA5`
- **Explorer**: https://sepolia.etherscan.io/address/0xc10753dB0CF87309Be84E57323A5C93E17c47040

## Security-First Development
- Follow Checks-Effects-Interactions (CEI) pattern in every external-facing function
- Use OpenZeppelin contracts where possible (battle-tested)
- Prefer explicit over implicit (no magic numbers, no unnamed return values)
- Every state-changing function needs an event
- Pin compiler version (no floating pragma)
- Add NatSpec documentation to all public/external functions
- Write tests that specifically target attack vectors, not just happy paths
- All divisions must have a documented rounding direction that favors the protocol
- Guard against zero-value transfers for token compatibility
- Use `nonReentrantView` on any view function returning price-sensitive state
