# Lending Oracle Lab (input 1)

Deliberately vulnerable DeFi lending laboratory built inside the Damn Vulnerable DeFi
Foundry workspace. It is the unfinished starting point for the oracle-manipulation
assessment.

## What exists

- `src/LendingPool.sol` - collateral deposits, LTV-bounded borrowing, repayment and
  collateral withdrawal. No interest, no liquidation engine.
- `src/SimpleAMM.sol` - constant-product USDC/WETH market with reserve math and a
  cumulative-price accumulator.
- `src/SpotPriceOracle.sol` - collateral oracle that returns the **instantaneous AMM
  spot price**. Decimal normalization is correct; freshness/sanity/manipulation checks
  are absent.
- `src/FlashLoanPool.sol` and `src/OracleAttackReceiver.sol` - ERC-3156-style flash
  capital and a ready-made manipulation receiver.
- `test/LendingPool.t.sol` - partial unit coverage only.
- `test/ForkBaseline.t.sol` - baseline fork checks plus a stub manipulation test.
- `test/FlashLoanSimulation.t.sol` - partial flash-loan plumbing test.

## Fixed environment

- Ethereum mainnet fork at block `26_000_000` by default (`FORK_BLOCK` overrides it).
- Real mainnet USDC (6 decimals) and WETH (18 decimals).
- Local AMM seeded with `2_000_000 USDC / 1_000 WETH`.
- Lending pool funded with `5_000_000 USDC`; flash pool with `2_000_000 USDC`.
- LTV `80%`, liquidation threshold `85%`.

## Run

```bash
cd lending-oracle-lab
export MAINNET_FORKING_URL=<archive-rpc-url>
forge test -vv
```

Expected at hand-off: baseline and unit tests pass; the manipulation test is still a
stub, so the core security question is unanswered.

## Known gaps

1. No proof that flash-loan-induced spot distortion lets a borrower exceed safe LTV.
2. No measurement of bad debt after the market price normalizes.
3. No staleness, deviation, sanity or fallback validation around the oracle.
4. No regression or fuzz properties for abnormal pricing.
