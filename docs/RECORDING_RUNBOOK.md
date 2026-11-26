# 50-minute recording runbook

## Pre-flight (off camera, 10 minutes)

```bash
cd /home/volleyking/writer/damn-vulnerable-defi
export MAINNET_FORKING_URL="<archive-rpc-url>"
export FORK_BLOCK=26000000
cd lending-oracle-lab && forge test --match-path test/ForkBaseline.t.sol -q
cd ../deliverables/final-output-2 && forge test --match-path 'test/OracleGuard.regression.t.sol' -q
```

Keep these open: `src/LendingPool.sol`, `src/SpotPriceOracle.sol`, `src/SimpleAMM.sol`,
`src/OracleAttackReceiver.sol`, terminal in the repo root. Close notifications. Use a
large font. Test the RPC; the fork call must complete before recording. If the provider
is slow, pre-warm by running the PoC once so the fork block is cached.

Timing rule: start Phase 4 by minute 26 even if Phase 3 overran. If Phase 3 overruns by
more than 4 minutes, skip the small-loan test and say so. Never skip validation.

---

## 0:00–2:00 — Scope and claim

Say:

> "I'm assessing a deliberately vulnerable lending lab on an Ethereum mainnet fork at
> block 26,000,000. My claim is that the pool borrows against an instantaneous AMM spot
> price, so a flash loan can inflate collateral, over-borrow, and leave bad debt once
> arbitrage restores price. I'll prove it, isolate the root cause with a trace, replace
> the oracle with a guarded TWAP, and verify the fix with regression and fuzz tests."

Show the tree: input lab, final output 1, final output 2, final output 3. State the
constraint: no broadcast, fixed block, real USDC/WETH decimals, 50 minutes.

Judgment call to voice: flash loan versus root cause (see `JUDGMENT_CALLS.md` #1).

## 2:00–8:00 — Phase 1: protocol analysis

Open `LendingPool.sol`. Trace:

- `borrow` → `maxBorrow` → `_collateralValue` → `oracle.getPrice()`;
- `deposit` has no price use;
- `withdraw` checks `_isCollateralized` against the same oracle;
- decimals are normalized once from 18 to 6 at `_collateralValue`.

Open `SpotPriceOracle.sol`. Point at the single line returning
`amm.spotPrice1In0()`. Say explicitly: "correct decimal normalization, no freshness,
no sanity, no manipulation resistance."

Open `SimpleAMM.sol`. Show `spotPrice1In0` deriving price from `reserve0/reserve1` and
show that a swap updates reserves inside the same transaction. State the trust boundary:
the pool trusts the AMM's current reserves.

Write the root-cause sentence in the terminal comments or a scratch note:

> "Collateral valuation is a same-transaction function of movable AMM reserves."

Judgment call: where to stop the analysis before testing (#1 dependency).

## 8:00–16:00 — Phase 2: baseline and math

Run the baseline:

```bash
cd lending-oracle-lab
forge test --match-path test/ForkBaseline.t.sol -vv
```

On screen, walk through the numbers:

- reserves: 2,000,000 USDC / 1,000 WETH;
- normalized price: 2,000e18;
- 500 WETH maximum borrow: 800,000e6;
- flash capital: 2,000,000e6, which is 2.5x the safe borrow;
- USDC is 6 decimals, WETH is 18; the 18-decimal oracle output is divided by 1e12 once.

Compute the constant-product effect aloud: after buying with 2M USDC, reserves become
~4M / ~500, spot ~8,000. "The safe amount is 800k, so a 2M loan can support 4x
over-borrowing."

Judgment call: why 2M is a defensible severity choice (#7).

## 16:00–26:00 — Phase 3: exploit and root cause

Copy the PoC into the lab test directory and run it:

```bash
cp ../deliverables/final-output-1/FlashLoanOracleManipulation.t.sol test/
forge test --match-test test_flashLoanSpotOracleManipulation -vv
```

Read every logged checkpoint: baseline 2,000; manipulated 7,988; borrowed 3,190,400;
profit 1,188,600; restored collateral 999,996; bad debt 2,190,404; health 0.266; pool
cash 1,809,600.

Then run the trace and stop at the borrow:

```bash
forge test --match-test test_flashLoanSpotOracleManipulation -vvvv
```

Point at the order:

1. `swapExactTokensForTokens` writes new reserves;
2. `deposit` succeeds;
3. `maxBorrow` calls `SpotPriceOracle::getPrice`;
4. `SimpleAMM::spotPrice1In0` returns the moved reserve ratio;
5. `borrow` transfers 3.19M USDC.

Say: "The loan did not create the debt; the price did. The borrow succeeds because the
pool reads the moved reserves, not because the transaction succeeded."

Run the small-loan test to show scaling:

```bash
forge test --match-test test_smallFlashLoanStillOverBorrows -vv
```

Judgment calls: attack size and restoration method (#6, #7). Note that the vulnerable
protocol's own `healthFactor` is still >1 before restoration, which is why checking only
the transaction would miss the issue.

## 26:00–38:00 — Phase 4: mitigation

Open `deliverables/final-output-2/src/oracle/TwapPriceOracle.sol`.

Walk through, in this order:

1. cumulative AMM price and ring-buffer observations;
2. `getPrice` interpolates the cumulative at `now - 30 minutes`;
3. same-block manipulation adds zero elapsed time, so the TWAP is unchanged;
4. guards: 40-minute staleness, 15% spot deviation, 100–100,000 USDC bounds, zero check;
5. 5-minute minimum update interval and permissionless keeper update;
6. decimal normalization to 18 decimals;
7. borrow-token conversion remains in the pool.

Open `ChainlinkPriceOracle.sol` and compare: independent market, but feed liveness,
staleness and 8-decimal normalization are now the trust surface. State why it is the
alternative rather than the default: no external dependency on the primary path.

Voice the trade-off: rejecting above 15% can freeze borrowing during extreme volatility;
the fuzz suite proves 14% still works, and TWAP-only still caps the borrow if the guard
is disabled. This is the "prevent without over-restricting" balance.

Judgment calls: architecture, window, reject-vs-clamp, threshold (#2–#5). Mention the
post-recording list.

## 38:00–48:00 — Phase 5: validation

Run the regression suite:

```bash
cd ../deliverables/final-output-2
forge test --match-path 'test/OracleGuard.regression.t.sol' -vv
```

Call out the key tests as they pass:

- same-block 2M pump reverts with `ExcessiveSpotDeviation(29939)`;
- TWAP-only path borrows ≤ 800k and health stays ≥ 1.0;
- 14% move is accepted;
- stale and missing-window prices revert;
- bounds, zero/round, LTV boundary, repay cap and decimal normalization pass;
- legitimate borrow/repay/withdraw succeeds.

Run fuzz at a recording-friendly count, then state the CI count:

```bash
forge test --match-path 'test/LendingPool.fuzz.t.sol' --fuzz-runs 128
forge test --match-path 'test/OracleGuard.fuzz.t.sol' --fuzz-runs 128
```

Point at the properties, not just green text: same-block pump never moves TWAP; guard
boundary matches the 15% threshold; staleness states; update cadence; Chainlink decimal
normalization; LTV boundary; partial repay; solvency conservation.

Confirm the final count: `29 tests passed` at 512 runs (pre-run evidence). If time is
short, run at 64 and say the pre-run was 512.

## 48:00–50:00 — Close

Summarize in four sentences:

1. Root cause: borrowing against instantaneous AMM spot.
2. Impact: 4x over-borrow, 1.19M profit, 2.19M bad debt, health 0.27.
3. Fix: 30-minute guarded TWAP plus bounds/staleness/deviation; Chainlink alternative.
4. Residual risk: sustained manipulation beyond the window and keeper liveness; no
   liquidation engine yet.

Show `docs/JUDGMENT_CALLS.md` post-recording section and say which calls changed versus
the pre-list.

Stop at 50:00.

---

## Failure fallbacks

- **RPC fails mid-run:** stop, state the error, use the pre-run logs/screenshots, and
  continue with the trace already captured. Do not claim a fresh run.
- **Fuzz run is slow:** lower to 32 runs and cite the 512-run artifact.
- **PoC assertion fails:** read the failing assertion, explain whether it is a severity
  assumption or an accounting error, and adjust on camera rather than hiding it.
- **Time overrun at Phase 3:** skip the small-loan variant; go straight to mitigation.
- **Contract compile issue:** run `forge build` and show the error; do not edit silently.

## One-command sanity check

```bash
forge test --match-path 'test/*.t.sol' --fuzz-runs 512
```

Expected: 29 passed, 0 failed in the fixed workspace.
