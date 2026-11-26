# Submission manifest

## Goals traceability

| Goal requirement | Artifact | Verification |
|---|---|---|
| Fork-based investigation of oracle manipulation | `final output 1.t.sol` | Run against input 1; two tests pass |
| Reproducible PoC | Pinned block `26_000_000`, real USDC/WETH, deterministic local AMM | Same numbers on every run |
| Improved oracle validation | `final output 2/src/oracle/TwapPriceOracle.sol` | 15% deviation, staleness, bounds, zero, rate-limit checks |
| Decimal normalization | `final output 2/src/LendingPool.sol`, both oracles | 6/18 decimal boundary test |
| Regression suite | `final output 3/OracleGuard.regression.t.sol` | 14 tests pass |
| Fuzz suite | `final output 3/LendingPool.fuzz.t.sol`, `OracleGuard.fuzz.t.sol` | 15 tests pass at 512 runs |
| Prevent unsafe valuation without blocking legitimate use | TWAP-only fallback + 14% acceptance test | Borrow stays ≤ safe max; health ≥ 1.0 |
| Document residual assumptions | `final output 2/README.md`, `docs/THREAT_MODEL.md` | Stated, not hidden |

## Zip contents

| Zip entry | Source | Type |
|---|---|---|
| `input 1/` | `lending-oracle-lab/` minus build output and the completed PoC | folder |
| `final output 1.t.sol` | `deliverables/final-output-1/FlashLoanOracleManipulation.t.sol` | `.t.sol` |
| `final output 2/` | `deliverables/final-output-2/` | folder |
| `final output 3/` | `deliverables/final-output-3/` | folder |
| `docs/` | Brief, threat model, judgment calls, runbook, this manifest | folder |

`input 1` is intentionally incomplete: it contains the vulnerable protocol, flash-loan
receiver, partial unit/fork tests and the explicit manipulation stub. The completed PoC
lives only in final output 1.

## Reproduce from the zip

```bash
unzip Deliverables.zip -d assessment
cd assessment/input 1
export MAINNET_FORKING_URL=<archive-rpc-url>
forge test                                   # partial suite: 9 passed, manipulation stub included

cp "../final output 1.t.sol" test/
forge test --match-test test_flashLoanSpotOracleManipulation -vv   # exploit

cd "../final output 2"
forge test --fuzz-runs 512                  # 29 passed, 0 failed
```

Both input and fixed folders bundle `lib/forge-std`, so no `forge install` is required.
An archive RPC for block `26_000_000` is required; the repo `.env` key is not embedded.

## Observed evidence (fixed block)

- The vulnerable PoC borrows 3,190,399.999999 USDC against 499.248873 WETH, keeps
  1,188,599.999999 USDC profit, and leaves 2,190,403.947639 USDC bad debt after price
  restoration.
- The fixed protocol rejects the same pump with `ExcessiveSpotDeviation(29939)`.
- With the guard disabled, the TWAP limits the same attack to 798,720e6 USDC and health
  stays above 1.0.
- Regression: 14/14. Fuzz: 15/15 at 512 runs.

## Naming note

The zip uses the exact item names from the task form (`input 1`, `final output 1.t.sol`,
`final output 2`, `final output 3`). Internal paths retain descriptive filenames for
navigation.
