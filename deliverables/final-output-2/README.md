# Final output 2: hardened protocol and secure oracle

This folder is the modified version of input 1. The vulnerable spot oracle is replaced
by a guarded AMM TWAP. The pool, AMM, flash lender and attack receiver stay in place so
the PoC and regression suites can run against the same system.

## Changed files

| File | Change |
|---|---|
| `src/oracle/TwapPriceOracle.sol` | New: 30-minute cumulative TWAP, observation ring buffer, 5-minute update interval, 40-minute staleness ceiling, 15% deviation bound, 100–100,000 USDC bounds, zero/ready checks, 18-decimal output |
| `src/LendingPool.sol` | Prices collateral through the oracle; adds reentrancy guard, totalCollateral accounting, custom errors, constant-time repay cap, explicit 18→borrow-decimal conversion |
| `src/oracle/ChainlinkPriceOracle.sol` | New alternative feed adapter: round completeness, freshness, positive answer, bounds, decimal normalization |
| `src/interfaces/AggregatorV3Interface.sol` | Chainlink interface for the alternative path |
| `foundry.toml`, `remappings.txt` | Standalone build config for this folder |
| `test/` | Verification copy of final output 3 (14 regression + 15 fuzz tests) |

Unchanged by design: `SimpleAMM.sol`, `SpotPriceOracle.sol` (kept for comparison),
`FlashLoanPool.sol`, `OracleAttackReceiver.sol`, token interfaces and mocks.

## Oracle design

`getPrice()` never returns spot. It:

1. rejects uninitialized, stale, and no-observation-in-window states;
2. interpolates the cumulative price at `block.timestamp - 30 minutes`;
3. divides the elapsed cumulative delta by the window;
4. rejects out-of-bounds prices and zero spot;
5. rejects a spot price more than 15% away from the TWAP.

A same-block manipulation accrues zero elapsed time, so the value is unchanged. The
15% guard then rejects the ~299% flash pump rather than valuing at a price that will
disappear. If the guard is disabled, the TWAP alone still holds the borrow to the safe
LTV.

### Alternative considered

Chainlink is independent of the AMM and cheaper to integrate, but adds feed-owner,
heartbeat, aggregator and 8-decimal normalization trust. It is implemented and tested as
an alternative, not the default. A dual/median oracle is the strongest option but needs
a disagreement policy; it is left for a follow-on task.

## Configuration

| Parameter | Value | Rationale |
|---|---|---|
| TWAP window | 30 minutes | Blocks atomic moves; tolerates normal volatility |
| Minimum update interval | 5 minutes | Bounds keeper gas and observation writes |
| Maximum staleness | 40 minutes | Borrowing freezes before the window has no recent point |
| Maximum spot deviation | 15% | Above day-to-day moves, below the 299% pump |
| Price bounds | 100–100,000 USDC | Rejects zero and absurd values |
| Observation buffer | 64 slots | Covers >5 hours at minimum cadence |

## Run

From this folder:

```bash
export MAINNET_FORKING_URL=<archive-rpc-url>
forge test --fuzz-runs 512
```

Expected: **29 passed, 0 failed**. The fork block defaults to `26_000_000`; override with
`FORK_BLOCK`.

Key checks:

```bash
forge test --match-test test_sameBlockFlashPumpRevertsOnDeviation -vv
forge test --match-test test_twapOnlyAttackCannotOverBorrow -vv
forge test --match-path 'test/*.fuzz.t.sol' --fuzz-runs 512
```

## Residual risks

- Sustained manipulation past 30 minutes moves the TWAP.
- Keeper liveness is now a borrowing dependency.
- TWAP and spot share one AMM; AMM compromise/drain affects both.
- No liquidation engine yet, so bad debt is not socialized.
- USDC/WETH return values are assumed to revert on failure (true for both, but not a
  general ERC-20 guarantee).
