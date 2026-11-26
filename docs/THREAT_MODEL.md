# Threat model and findings

## 1. System model

| Component | Trust assumption |
|---|---|
| `LendingPool` | Holds 5,000,000 USDC and values WETH collateral through one oracle call |
| `SpotPriceOracle` | Returns `reserveUSDC / reserveWETH` from the AMM, normalized to 18 decimals |
| `SimpleAMM` | Constant-product market seeded with 2,000,000 USDC / 1,000 WETH; anyone can swap |
| `FlashLoanPool` | Lends 2,000,000 USDC atomically for a 9 bps fee |
| Keeper / arbitrageur | Restores the AMM after the atomic transaction ends |

LTV is 80%; liquidation threshold is 85%. There is no interest or liquidation engine.

## 2. Root cause

`LendingPool._collateralValue` calls `oracle.getPrice()` at the moment of borrowing.
The vulnerable oracle is:

```solidity
return amm.spotPrice1In0();
```

A swap changes AMM reserves immediately. A flash loan supplies enough capital to move
those reserves by ~4x, and the whole sequence settles atomically. The pool therefore
prices collateral at a value that exists only inside the attack transaction. There is
no TWAP, no staleness check, no deviation bound, and no sanity range.

The flash loan is **not** the root cause. It is temporary capital. A swap funded with
the attacker's own 2M USDC would produce the same distorted valuation; the flash loan
only removes the capital requirement.

## 3. Enabling conditions

1. Borrowing capacity is a function of a same-transaction spot price.
2. The AMM is thin relative to available atomic liquidity (2M USDC versus 2M USDC /
   1,000 WETH reserves).
3. LTV (80%) is applied to the inflated value rather than a time-weighted value.
4. No price-validation gate exists in the borrow path.
5. No liquidation occurs before arbitrage restores the market, so over-borrow is not
   corrected by a margin call in the same block.

## 4. Attack path

1. Attacker flash-borrows 2,000,000 USDC (fee 1,800 USDC).
2. Buys WETH on the AMM. Reserves go from `2,000,000 / 1,000` to
   `~4,000,000 / ~500`; spot jumps from 2,000 to ~7,988 USDC/WETH.
3. Deposits ~499.25 WETH. The oracle values it at the manipulated price.
4. Borrows the 80% maximum: ~3,190,400 USDC.
5. Repays the 2,001,800 USDC flash loan from borrowed funds; keeps ~1,188,600 USDC.
6. Arbitrageurs sell WETH back. Price returns to ~2,003; the collateral is worth
   ~1,000,000 USDC while debt is ~3,190,400 USDC.
7. Protocol bad debt: ~2,190,404 USDC. Health factor: ~0.266.

Observed from the fork PoC:

| Metric | Value |
|---|---|
| Baseline price | 2,000.00 USDC/WETH |
| Safe borrow for 500 WETH | 800,000 USDC |
| Manipulated price | 7,988.00 USDC/WETH |
| Borrowed | 3,190,399.999999 USDC |
| Profit | 1,188,599.999999 USDC |
| Restored collateral value | 999,996.052360 USDC |
| Bad debt | 2,190,403.947639 USDC |
| Pool USDC remaining | 1,809,600.000001 USDC |
| Health factor | 0.2664 |

## 5. Why a successful transaction is not enough

A successful borrow proves only that the call did not revert. The PoC additionally
asserts the baseline, the safe maximum, the debt change, the attacker's net profit,
the post-arbitrage collateral value, the bad-debt amount, the pool's remaining cash,
and the health factor. The trace is used to attribute the borrow increase to the
reserve movement, not to unrelated accounting.

## 6. Invariants

- Economic: for every account, `debt <= collateralValue * liquidationThreshold / 1e18`
  under normal pricing after any operation.
- Oracle: a same-block spot move does not change the TWAP used by `borrow`.
- Accounting: `borrowToken.balanceOf(pool) + totalDebt == initialLiquidity`.
- Custody: `collateral.balanceOf(pool) == totalCollateral`.
- Decimal: 18-decimal oracle output converts to 6-decimal borrow units exactly once.
- Oracle liveness: price is rejected if the latest observation is stale, missing from
  the window, zero, outside configured bounds, or deviating beyond the bound.

## 7. Mitigation options

| Option | Manipulation resistance | Latency / availability | Complexity | Notes |
|---|---|---|---|---|
| Keep spot, add deviation check | Low; same-block move still used | High | Low | Does not fix valuation, only rejects outliers |
| AMM TWAP + guards | High for atomic moves; cost grows with window | Medium; needs keeper and warm-up | Medium | On-chain, no external dependency, uses existing accumulator |
| Chainlink feed + checks | High; independent market | Depends on feed heartbeat and liveness | Low integration, external trust | Staleness/round/bounds checks required; 8-decimal normalization |
| Dual oracle / median | Highest | Medium | High | Cross-checks feeds but introduces correlated-failure decisions |

**Chosen:** TWAP as the valuation source with a 30-minute window, 5-minute update
interval, 40-minute staleness ceiling, 15% spot-deviation bound, and 100–100,000 USDC
sanity bounds. A Chainlink adapter with round completeness, staleness, positivity,
bounds and decimal checks is included as the documented alternative and tested against
a mock feed.

The 15% deviation bound rejects the 299% flash pump outright. With deviation checking
disabled, the TWAP alone caps the attack borrow at ~798,000 USDC and keeps the position
above a 1.0 health factor. This proves the TWAP is doing the real work and the guard is
defence in depth, not a substitute.

## 8. Residual risks

- Sustained manipulation longer than the 30-minute window will move the TWAP.
- A stalled keeper eventually blocks borrowing and debt-backed withdrawals.
- The TWAP uses the same AMM the protocol prices from; if the AMM itself is compromised
  or drained, both spot and TWAP fail. Bounds and zero-reserve checks help but are not a
  second market.
- Chainlink introduces feed-owner, heartbeat and aggregator trust.
- No interest or liquidation means bad debt persists until a follow-on task adds it.
- `SimpleAMM` has no minimum-liquidity lock; first-depositor share inflation is out of
  scope.
- Token return values are unchecked; USDC/WETH revert on failure, but arbitrary tokens
  would need `SafeERC20`.
