You are performing a security audit on the smart contracts in this project. This is for a hackathon where judges will run automated and manual audits to find vulnerabilities. Be thorough and adversarial.

## Audit Process

### Step 1: Discover contracts
Find all Solidity files (*.sol) in the project. List them and identify which are core contracts vs interfaces/libraries.

### Step 2: Search web3 knowledge vault
Search the `web3` QMD collection (using `mcp__qmd__deep_search` with `collection: "web3"`) for any relevant vulnerability patterns, audit notes, or security guidance that applies to the contracts found. Use this knowledge to inform the audit.

### Step 3: Check each vulnerability class
For every contract, systematically check for:

**Critical:**
- [ ] **Reentrancy**: External calls before state updates. Check all functions with `.call`, `.transfer`, `.send`, or calls to external contracts. Verify CEI (Checks-Effects-Interactions) pattern or ReentrancyGuard.
- [ ] **Access control**: Missing `onlyOwner`/role checks on sensitive functions (pause, mint, set fees, withdraw, upgrade). Check initializer protection.
- [ ] **Flash loan attack surface**: Can pool state be manipulated and exploited within a single transaction?
- [ ] **Integer overflow/underflow**: Unchecked arithmetic in price calculations, fee computations, or token amount conversions. Note: Solidity 0.8+ has built-in checks, but `unchecked {}` blocks bypass them.
- [ ] **Delegatecall injection**: Any use of `delegatecall` with user-controlled addresses.
- [ ] **Uninitialized storage/proxy issues**: If upgradeable, check storage layout collisions.

**High:**
- [ ] **Oracle manipulation**: Price feeds derived from pool reserves (spot price). Are TWAPs or external oracles used instead?
- [ ] **Sandwich/frontrunning**: Is there slippage protection? Are deadline parameters enforced?
- [ ] **Token compatibility**: Does the DEX handle fee-on-transfer tokens, rebasing tokens, or tokens with non-standard return values (USDT)?
- [ ] **Approval race conditions**: ERC20 approve front-running.
- [ ] **Unchecked return values**: Low-level calls where return value is ignored.

**Medium:**
- [ ] **Centralization risks**: Owner can drain funds, pause indefinitely, change fees to 100%?
- [ ] **Rounding errors**: In AMM math (constant product, fee calculation), which direction do rounding errors favor?
- [ ] **Event emission**: Missing events on state changes (breaks off-chain monitoring).
- [ ] **Denial of service**: Unbounded loops, block gas limit issues, griefing vectors.
- [ ] **Timestamp dependence**: Using `block.timestamp` for critical logic.

**Low:**
- [ ] **Compiler version**: Is pragma pinned? Using latest stable?
- [ ] **License identifier**: SPDX present?
- [ ] **NatSpec documentation**: Are public functions documented?
- [ ] **Gas optimization**: Obvious inefficiencies that could affect usability.

### Step 4: Report
Present findings as:

```
## Audit Report: [Contract Name]

### CRITICAL
- [Finding]: [Description + exact line reference + exploit scenario]

### HIGH
- ...

### MEDIUM
- ...

### LOW / Informational
- ...

### Passed Checks
- [List checks that passed with brief explanation]
```

### Step 5: Save findings
If any CRITICAL or HIGH findings are discovered, create a note in the web3 knowledge vault at `/Users/samuelvirag/SmoothOperators/ChSmartContract/knowledge/notes/` documenting the pattern for future reference.

$ARGUMENTS - Optional: path to a specific contract file to audit. If not provided, audit all contracts.
