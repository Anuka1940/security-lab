# Flash-loan oracle manipulation assessment — materials

This package contains a complete, reproducible assessment lab for a lending protocol
that trusts an AMM spot price. It is built from the Damn Vulnerable DeFi Foundry
environment and uses an Ethereum mainnet fork at a fixed block with real USDC/WETH
decimals.

## Contents

| Path | Purpose |
|---|---|
| `ASSESSMENT_BRIEF.md` | Objective, scope, explicit assertions, definition of done |
| `THREAT_MODEL.md` | Root cause, enabling conditions, attack path, impacts, mitigation comparison, residual risks |
| `JUDGMENT_CALLS.md` | Eight decisions with options/trade-offs, plus the post-recording list |
| `RECORDING_RUNBOOK.md` | Minute-by-minute 50-minute script with commands and fallbacks |
| `SUBMISSION_MANIFEST.md` | Deliverable mapping and reproduction commands |
| `EXPECTED_EVIDENCE.txt` | Reference output and trace ordering for fallback during recording |

## Artifacts

- `input 1/` — vulnerable lab with partial tests and a manipulation stub.
- `final output 1.t.sol` — fork PoC: 4x over-borrow, 1.19M profit, 2.19M bad debt.
- `final output 2/` — guarded TWAP + hardened pool + Chainlink alternative.
- `final output 3/` — 14 regression and 15 fuzz properties; 512-run clean.

## Headline numbers

| | Vulnerable | Fixed |
|---|---|---|
| Same-block 2M pump | 3,190,400 USDC borrowed | Reverts `ExcessiveSpotDeviation(29939)` |
| TWAP-only fallback | n/a | 798,720 USDC borrowed; health ≥ 1.0 |
| Post-restore health | 0.266 | ≥ 1.0 |
| Bad debt | 2,190,404 USDC | 0 in tested path |

Read the brief and threat model first; run the book in `RECORDING_RUNBOOK.md` for the
recorded walkthrough.
