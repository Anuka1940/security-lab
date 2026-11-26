# Assessment brief: flash-loan oracle manipulation in a lending pool

## Objective

Prove, isolate, fix, and regression-test a collateral-valuation vulnerability in a
deliberately vulnerable DeFi lending lab. The deliverable is a reproducible Ethereum
mainnet-fork investigation, not a successful-transaction screenshot.

## Starting point

`lending-oracle-lab/` (input 1) already contains:

- collateral custody, LTV checks, borrowing and repayment;
- a local constant-product USDC/WETH AMM with a cumulative-price accumulator;
- a `SpotPriceOracle` returning the instantaneous AMM price;
- an ERC-3156-style flash lender and attack receiver;
- an incomplete Foundry suite with an explicit manipulation-test stub.

The lab works at baseline. The unanswered question is whether a flash loan can make
collateral appear more valuable than it is.

## Security question

Can an attacker atomically:

1. borrow uncollateralized stablecoin,
2. move the AMM's spot price,
3. deposit collateral valued at the distorted price,
4. borrow more than the true-value LTV permits,
5. repay the flash loan and leave the pool insolvent when arbitrage restores price?

The distinction that matters: the flash loan is the **enabling condition**. The
vulnerability is the lending pool's **trust in a manipulable instantaneous price**.

## Required evidence

| Phase | Evidence | Pass condition |
|---|---|---|
| 1. Protocol analysis | Call graph and trust-boundary map from `borrow` to AMM reserves | Root cause named before exploitation |
| 2. Baseline | Fixed fork block, decimal checks, baseline reserves/price/max borrow | Safe borrow for 500 WETH is 800,000 USDC, below the 2M flash size |
| 3. Exploit | Fork PoC, expected-vs-observed assertions, trace of reserve and debt changes | Borrow exceeds safe max; profit > 1M; post-restore debt > collateral value |
| 4. Mitigation | Guarded TWAP implementation plus Chainlink alternative | Same-block pump rejected; TWAP-only path borrows within safe LTV |
| 5. Validation | Regression + fuzz properties | Attack prevented; borrow/repay/withdraw and decimal boundaries still work |

## Explicit security assertions

- `price_before == 2,000e18`.
- `safe_max_borrow(500 WETH) == 800,000e6 < flash_loan(2,000,000e6)`.
- After the pump, `borrowed ≈ 3,190,400e6` (about 4x safe max).
- `attacker_profit > 1,000,000e6` after flash-loan fee.
- After market-price restoration, `debt > collateral_value` and `bad_debt > 2,000,000e6`.
- Health factor after restoration is `< 1e18`.
- Fixed path: same-block attack reverts on excessive deviation; with deviation checks
  disabled, TWAP limits the borrow to `≤ 800,000e6` and health stays `≥ 1e18`.
- Fuzz: every borrow at or below the LTV-derived maximum succeeds; one unit above
  reverts; round trips conserve balances; `cash + totalDebt` stays constant.

## Environment constraints

- Ethereum mainnet fork pinned at block `26_000_000`.
- Real mainnet USDC (6 decimals) and WETH (18 decimals).
- No transaction broadcast; anvil/fork only.
- ABI/address assumptions held fixed for the recording.
- 50-minute wall clock; the runbook allocates time per phase and keeps slow fuzz runs
  at the end.

## Non-goals

Interest accrual, liquidations, bad-debt socialization, ERC-4626 vault integration,
read-only reentrancy and gas optimization are follow-on tasks. The lab exposes hooks
for them (total debt/collateral accounting, health factor, oracle interface).

## Definition of done

1. The PoC fails against `SpotPriceOracle` and passes with the hardened oracle.
2. The regression suite catches a reintroduction of direct spot pricing.
3. The fuzz suite passes at 512 runs and covers the LTV boundary, decimal scaling,
   staleness, deviations and accounting conservation.
4. Remaining assumptions are documented rather than hidden.
