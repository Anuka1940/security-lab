# Judgment calls

Pre-recording list. Each entry names the decision, the alternatives, the trade-off and
the experience required to weigh it. Dependencies are called out so the recording can
show that later choices are informed by earlier evidence.

## 1. Is the flash loan the bug or the delivery mechanism?

- Options: frame the finding as "flash-loan attack"; frame it as "unsafe spot-oracle
  dependency with an atomic-capital enabler".
- Trade-off: the first is easy to say but leads to mitigations that only cover flash
  loans. The second points at valuation and generalizes to any atomic capital source.
- Experience: requires separating a root cause from its enabling conditions and
  predicting which fixes survive a change in attacker funding.
- Evidence needed: same-block reserve movement, unchanged TWAP, and a trace showing the
  borrow calculation reading manipulated reserves.
- Decision: flash loan is enabling; spot dependency is the vulnerability.
- Depends on: Phase 1 call-graph analysis and Phase 2 reserve math.

## 2. Which oracle architecture?

- Options: keep spot plus a deviation check; AMM TWAP; Chainlink; dual oracle/median.
- Trade-off: spot+deviation is cheap but still borrows at the bad price if the move is
  under the threshold. Chainlink is independent but adds feed liveness and decimal
  handling. TWAP resists single-block moves but adds warm-up, keeper and window latency.
  A dual oracle is strongest but doubles the failure surface and needs a policy for
  disagreement.
- Experience: DeFi oracles fail on liveness, not only accuracy; a technically stronger
  feed can still be operationally worse.
- Decision: guarded TWAP as the live path; Chainlink adapter as documented alternative.
- Depends on: confirming the AMM has a usable cumulative accumulator and that a 30-minute
  window blocks the observed 4x move.

## 3. TWAP window and update cadence

- Options: 15, 30 or 60 minutes; 1, 5 or 15-minute heartbeat.
- Trade-off: longer windows resist more manipulation but stale faster and lengthen the
  warm-up. Shorter windows track the market but let a sustained pump through.
- Experience: choose against block time, keeper reliability and expected volatility, not
  just the exploit size.
- Decision: 30-minute window, 5-minute minimum update, 40-minute hard staleness ceiling.
- Depends on: measured attack duration (one block) and the PoC's post-restore behavior.

## 4. Reject or clamp when spot deviates?

- Options: revert above the bound; return the TWAP and ignore spot; clamp to a band.
- Trade-off: reverting protects valuation but can freeze borrowing in volatility.
  Ignoring spot maximizes availability but loses the secondary check. Clamping is
  smooth but hides disagreement.
- Experience: availability is a security property; a guard that blocks all legitimate
  use during a 16% move is a different failure.
- Decision: TWAP is always the value; only reject when deviation exceeds 15%. Fuzz the
  boundary and test a 14% move for acceptance.
- Depends on: observed 299% pump and a realistic moderate-volatility path.

## 5. Deviation threshold

- Options: 10%, 15%, 25%.
- Trade-off: 10% rejects normal volatility; 25% admits a large over-borrow. The threshold
  must sit above legitimate day-to-day moves and below the attack's ~300%.
- Experience: calibrating against market behavior and the protocol's LTV buffer, not a
  round number.
- Decision: 15%, with a fuzz test that passes at and below the bound and reverts above it.
- Depends on: the 80% LTV and the ability to demonstrate the TWAP-only fallback.

## 6. How to prove the market returned to normal

- Options: warp time; call a mock price setter; execute a real opposing swap.
- Trade-off: warping is deterministic but artificial; a real swap exercises AMM math and
  proves the collateral value collapses without a cheatcode.
- Experience: distinguish oracle input changes from market-state changes.
- Decision: execute a real keeper swap of 500 WETH, then assert price restoration,
  negative equity and bad debt.
- Depends on: Phase 3 confirming the exact reserve path.

## 7. How large should the PoC attack be?

- Options: a small loan that only over-borrows; a 2M loan that is self-repaying and
  profitable.
- Trade-off: small is fast and shows relative distortion; large proves economic impact
  and protocol insolvency but needs enough pool liquidity.
- Experience: severity must be shown in loss terms, not only "borrowed more".
- Decision: 2M primary PoC, plus a small-loan variant to show scaling.
- Depends on: baseline safe-borrow measurement and pool/flash liquidity.

## 8. Fuzz bounds: realistic or adversarial?

- Options: bound to operational ranges; allow extremes; both.
- Trade-off: realistic bounds find integration bugs; extremes find overflow and rounding.
  Too many nonsense inputs create rejected-test noise.
- Experience: pick bounds that preserve the property under test.
- Decision: LTV and decimal fuzz use operational ranges with exact boundary checks;
  staleness and deviation fuzz use the configured time and price ranges, including the
  revert boundary.
- Depends on: the fixed configuration and the assertions in Phase 5.

## Post-recording: calls actually made

1. Root cause: unsafe spot dependency; flash loan treated as enabler.
2. Architecture: guarded 30-minute TWAP, Chainlink adapter as alternative.
3. Guard policy: reject above 15% deviation, always value at TWAP.
4. Market restoration: real 500 WETH keeper swap, not a time warp.
5. Attack size: 2M primary plus small-loan sensitivity test.
6. Validation: 512-run fuzz plus 14 deterministic regressions.
7. Residual risk accepted: sustained >30-minute manipulation and keeper liveness.
