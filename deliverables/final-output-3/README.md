# Final output 3: regression and fuzz suite

These tests run against final output 2. They prove the flash-loan pricing failure is
prevented and that legitimate lending still works across normal and abnormal inputs.

## Files

- `BaseForkFixed.t.sol` — fork harness at block `26_000_000`, real USDC/WETH, warm TWAP,
  deployment and swap helpers.
- `OracleGuard.regression.t.sol` — 14 deterministic regressions.
- `LendingPool.fuzz.t.sol` — 7 accounting/LTV fuzz properties.
- `OracleGuard.fuzz.t.sol` — 8 oracle/guard fuzz properties.

## Regression coverage

| Test | Property |
|---|---|
| `test_initialState` | Baseline price, observation count, empty accounting, pool funding |
| `test_legitimateBorrowRepayWithdraw` | Full normal lifecycle at 50k debt |
| `test_repayIsCappedAtDebt` | Overpayment pulls only the debt |
| `test_withdrawBelowHealthReverts` | Withdrawal cannot break the liquidation threshold |
| `test_sameBlockFlashPumpRevertsOnDeviation` | The exact 2M PoC pump is rejected |
| `test_twapOnlyAttackCannotOverBorrow` | With the guard disabled, TWAP caps borrow ≤ 800k and health ≥ 1.0 |
| `test_staleOracleRevertsOnBorrow` | Borrow freezes after the staleness ceiling |
| `test_missingRecentObservationReverts` | No observation inside the window reverts |
| `test_moderateVolatilityIsAccepted` | A ~14% move still borrows |
| `test_priceBoundsRejected` | A TWAP outside configured bounds reverts |
| `test_updateRateLimit` | Same-block update reverts |
| `test_decimalNormalizationAtBorrowBoundary` | 18→6 conversion is exact and one unit over reverts |
| `test_chainlinkAlternativeNormalizesAndChecksStaleness` | 8-decimal feed normalizes; stale feed reverts |
| `test_constructorRejectsInvalidConfiguration` | Bad window and bounds fail closed |

## Fuzz coverage

| Test | Invariant |
|---|---|
| `testFuzz_borrowWithinLtv` | Every borrow at/below max succeeds with exact debt |
| `testFuzz_oneAboveMaxReverts` | One unit above max reverts |
| `testFuzz_repayThenWithdrawRoundTrip` | Repay then withdraw conserves balances |
| `testFuzz_partialRepay` | Partial repayment tracks exactly |
| `testFuzz_withdrawPreservesThreshold` | Any safe withdrawal keeps health ≥ 1.0 |
| `testFuzz_decimalNormalization` | Max borrow equals the exact 18→6 formula |
| `testFuzz_solvencyAccounting` | `cash + totalDebt` and collateral custody are conserved across two borrowers |
| `testFuzz_sameBlockPumpNeverMovesTwap` | Any same-block pump leaves the TWAP at 2,000 |
| `testFuzz_deviationGuardMatchesBoundary` | Reverts exactly above 15%, accepts at/below |
| `testFuzz_moderatePumpAccepted` | Bounded pumps always pass |
| `testFuzz_stalenessStates` | Fresh, no-window and stale states each behave correctly |
| `testFuzz_updateCadence` | Update succeeds only after 5 minutes |
| `testFuzz_minPriceBoundRejected` | Any min bound above market rejects |
| `testFuzz_chainlinkDecimalNormalization` | Every feed decimal count normalizes to 18 |
| `testFuzz_chainlinkStaleness` | Stale feed always reverts at the boundary |

## Run

Copy into the final-output-2 test directory (already present there), then:

```bash
cd ../final-output-2
export MAINNET_FORKING_URL=<archive-rpc-url>
forge test --match-path 'test/OracleGuard.regression.t.sol' -vv
forge test --match-path 'test/*.fuzz.t.sol' --fuzz-runs 512
```

Expected: 14 regression passed; 15 fuzz passed at 512 runs; 0 failed.

## Notes

- Fuzz runs each create a fresh fork snapshot; 512 runs is the CI count and completes in
  under 30 seconds.
- The harness uses real mainnet token addresses and decimal behavior. It deploys the AMM
  and protocol locally so the starting reserves are deterministic.
- The Chainlink staleness test uses a mock aggregator because the fixed fork's real feed
  age is not controllable.
