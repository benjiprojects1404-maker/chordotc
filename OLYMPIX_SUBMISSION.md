# ChordOTC: pre-audit security review for Olympix

## 1. Summary

- **Project:** ChordOTC (v1 escrow `ChordOTC` and v2 non-custodial `ChordOTCv2`), peer-to-peer ERC-20 <-> USDC OTC trades on Arc
- **Date:** 2026-11-19
- **Review level:** max (Critical, High, Medium, Low), plus Slither 0.11.6 and Foundry unit, fuzz and invariant tests (forge 1.7.1)
- **Solidity compiler:** 0.8.24 (EVM target: paris, optimizer on, 200 runs)
- **Scope:** every production Solidity contract in `contracts/`. Tests, mocks and `lib/` were skipped.
- **Not independently audited.** This is an AI-assisted internal review and does not replace a third-party audit.

| File | SHA-256 before the review | SHA-256 after the fixes |
|---|---|---|
| `contracts/ChordOTC.sol` | `534e4a4403df363183f96870de6543768d5dcc7b7b7bb625e8d77d24c857d8de` | `1301ed714c2fd4d9a73ccc7960da9312d1481d031ffe7f4d0aeccfdb06d4c177` |
| `contracts/ChordOTCv2.sol` | `09b358b13de0488632a51bff0394aa8310fb0b30dd501409ddccd2b2e137f06b` | `059e40c2ed9602abb7d7557a2c29e0742be7204fba281be3e3d10ee2b16cdbaa` |

Behavior changes made by the fixes:

- **F-01:** for non-USDC tokens, each token leg is now rejected unless both sides move by exactly the agreed amount. The error string is unchanged: "token took a transfer fee or rebased - unsupported".
  - v1 deposits also check the sender's balance drop.
  - v1 payouts from escrow (fill, cancel, withdraw) check both the escrow's drop and the recipient's gain.
  - v2 checks the payer's drop as well as the receiver's gain.
  - Standard ERC-20s and all USDC paths behave as before. Non-USDC token legs cost a few extra `balanceOf` calls.
- **F-06:** a v1 payout of a token that no longer has code now reverts instead of silently "succeeding" without moving anything. This is a side effect of the F-01 checks.
- **F-05:** the fee recipient can no longer be the contract's own address (constructor and `setFeeRecipient`, v1 and v2). Zero-address checks and error strings are unchanged.
- **F-21 and F-22:** the `setPaused` parameter is renamed from `_paused` to `newPaused` (ABI parameter name only; the selector `0x16c38b3c` is unchanged).
- **F-02:** documentation only. One sentence in the v1 header says that post-deposit downward rebases are not detected.

Notes:

- No file other than the two contracts, one new test file (`test/foundry/ChordOTC.review.t.sol`) and this report was changed. Nothing was deployed.
- The deployed Arc mainnet v1 bytecode will differ from this source. These changes take effect only if the contract is redeployed.
- The last two small edits (the recipient-balance check in v1 `_tryTransferExact` and the `senderBefore` restructure) came after the second reviewer pass. Both are covered by the full test run and the final Slither run, but the reviewers did not re-read them.

## 2. Findings

Line numbers refer to the files after the fixes.

| ID | Severity | Source | Title | File and line | Status | Fix or reason |
|---|---|---|---|---|---|---|
| F-01 | High | review | Token-leg accounting only checked the receiver, so a token charging the sender extra (or taxing only escrow payouts) could drain other offers (v1) or overcharge the payer (v2) | `ChordOTC.sol` L350-364, L380-395; `ChordOTCv2.sol` L318-328 | Fixed | Sender-side and recipient-side balance deltas are now enforced for non-USDC tokens. |
| F-02 | High | review | v1 escrow can become short if a rebasing token shrinks balances after deposit | `ChordOTC.sol` L350-364 (`_pullExact`) | Open | A transfer-time check cannot detect later rebases. The real fix is a token allowlist or share accounting, which changes behavior (see section 4). Header note added. |
| F-03 | Medium | review | If the USDC issuer blocklists the v1 escrow contract, all escrowed USDC is frozen (cancel, fill and withdraw all revert) | `ChordOTC.sol` L239-245 | Accepted risk | Issuer-dependent and inherent to a custodial escrow. v2 holds no funds and removes this risk. |
| F-04 | Medium | review | If the fee recipient is blocklisted, every fee-bearing v2 fill reverts until the owner changes it | `ChordOTCv2.sol` L179, L183 | Accepted risk | Documented design. No funds at risk. Recovery is `setFeeRecipient`. Offers snapshotted at 0% fee still fill. |
| F-05 | Low | review | Fee recipient could be set to the contract itself, stranding fees | `ChordOTC.sol` L146-152, L274-278; `ChordOTCv2.sol` L114-120, L237-241 | Fixed | `address(this)` is rejected in the constructor and in `setFeeRecipient`. |
| F-06 | Low | review | v1 payout of a token with no code (for example after self-destruct) appeared to succeed without moving funds | `ChordOTC.sol` L380-395 | Fixed | Closed by the F-01 balance checks, which revert on no-code tokens. |
| F-07 | Low | review | Unbounded return-data copy from token calls (return-data bomb) | `ChordOTC.sol` L374-379, L400-405; `ChordOTCv2.sol` L330-334 | Accepted risk | Only the party who chose to trade an attacker-chosen token can be griefed (gas only). USDC is trusted. |
| F-08 | Low | review | Fee rounds down to zero on very small trades (under 400 base units at 25 bps) | `ChordOTC.sol` L202; `ChordOTCv2.sol` L172 | Accepted risk | Economic only. Changing rounding changes fee economics. |
| F-09 | Low | review | v2 makers can over-commit one balance to several offers, or revoke allowance or move funds to make fills revert | `ChordOTCv2.sol` L219-225, L284-287 | Accepted risk | Inherent to the non-custodial design and documented. Takers lose only gas. `offerReady` shows stale offers. |
| F-10 | Low | review | Owner can pause v2 fills indefinitely (v1 pause only stops new offers) | `ChordOTCv2.sol` L164, L243-246; `ChordOTC.sol` L312 | Accepted risk | Intended admin control. Makers can always cancel, and no funds are held. |
| F-11 | Informational | review | An offer with an absurd `amountUsdc` (near 2^256) makes the fee multiplication overflow, so it can never be filled | `ChordOTC.sol` L202; `ChordOTCv2.sol` L172 | Accepted risk | Self-grief only: the maker can still cancel. Nothing else is affected. |
| F-12 | High | Slither | reentrancy-balance in `_moveExact` | `ChordOTCv2.sol` L318-328 | False positive | The only caller is guarded by `nonReentrant`. The balance deltas are the intended check. |
| F-13 | High | Slither | reentrancy-balance in `_pullExact` | `ChordOTC.sol` L350-364 | False positive | The only callers are guarded by `nonReentrant`. The balance deltas are the intended check. |
| F-14 | Medium | Slither | incorrect-equality in `_pullExact` | `ChordOTC.sol` L350-364 | False positive | Exact equality is the intended exact-amount check. |
| F-15 | Medium | Slither | incorrect-equality in `_moveExact` | `ChordOTCv2.sol` L318-328 | False positive | Exact equality is the intended exact-amount check. |
| F-16 | Medium | Slither | reentrancy-no-eth in v1 `fillOffer` (credits written after external calls) | `ChordOTC.sol` L193-220 | False positive | `fillOffer` and `withdraw` are both `nonReentrant`. Offer status is set before any external call. |
| F-17 | Low | Slither | timestamp comparisons (v1) | `ChordOTC.sol` L193, L223, L259, L308 | Accepted risk | Expiry is the intended feature and uses only `>` or `<=`, which is safe on Arc with repeated timestamps. |
| F-18 | Low | Slither | timestamp comparisons (v2) | `ChordOTCv2.sol` L163, L191, L212, L219, L271 | Accepted risk | Same as F-17. |
| F-19 | Informational | Slither | low-level calls (v1) | `ChordOTC.sol` L375, L401 | Accepted risk | Needed to support ERC-20s that return nothing. Return values are checked. |
| F-20 | Informational | Slither | low-level call (v2) | `ChordOTCv2.sol` L330 | Accepted risk | Same as F-19. |
| F-21 | Informational | Slither | naming-convention: `_paused` parameter (v1) | `ChordOTC.sol` L280 | Fixed | Renamed to `newPaused`. |
| F-22 | Informational | Slither | naming-convention: `_paused` parameter (v2) | `ChordOTCv2.sol` L243 | Fixed | Renamed to `newPaused`. |
| F-23 | High | Slither | reentrancy-balance in `_tryTransferExact` (raised after the F-01 fix) | `ChordOTC.sol` L380-395 | False positive | Same reasoning as F-13. |
| F-24 | Medium | Slither | incorrect-equality in `_tryTransferExact` (raised after the F-01 fix) | `ChordOTC.sol` L380-395 | False positive | Same reasoning as F-14. |
| F-25 | Medium | Slither | uninitialized-local `senderBefore` in `_pullExact` (raised after the F-01 fix) | `ChordOTC.sol` L352 | Fixed | The variable is now assigned in its declaration. |

Slither runs: 19 results before the fixes and 25 after. After the final fix the 25 are all covered by F-12 to F-20, F-23 and F-24, and there is no uninitialized-local result. The extra results are the same detectors firing at the new check sites. The second reviewer pass, before the last two small edits, found no new issues.

## 3. Tests

Commands run:

```
cd /home/user/app && forge test --match-path test/foundry/ChordOTC.review.t.sol -vv
cd /home/user/app && forge test
```

Final result of the full `forge test`: **76 passed, 0 failed, 2 skipped** (the 2 skips are the fork-test `setUp` entries, which need an RPC URL).

Test files:

- `test/foundry/ChordOTC.review.t.sol`: new, 41 tests, each named `test_F<NN>_...`.
- `test/foundry/ChordOTC.invariant.t.sol`: existing, 7 edge-case tests and 3 invariants (256 runs, depth 100).
- `test/foundry/ChordOTCv2.t.sol`: existing, 23 unit tests and 2 invariants.
- `test/foundry/ChordOTC.fork.t.sol` and `test/foundry/ChordOTCv2.fork.t.sol`: existing, skipped without a fork RPC.
- The Python suites (`test/test_chordotc.py`, `test/test_invariants.py`) were not run.

| Finding | Tests in `ChordOTC.review.t.sol` | Result |
|---|---|---|
| F-01 | `test_F01_v1_create_tokenGiving_senderSurchargeRejected`, `test_F01_v1_fill_takerPaysToken_senderSurchargeRejected`, `test_F01_v2_fill_takerPaysToken_senderSurchargeRejected`, `test_F01_v2_fill_makerPaysToken_senderSurchargeRejected`, `test_F01_v1_cancel_escrowOverDebited_reverts`, `test_F01_v1_fill_escrowOverDebited_reverts`, `test_F01_v1_cancel_recipientShortPaid_reverts`, `test_F01_v1_fill_recipientShortPaid_reverts`, `test_F01_v1_usdcLegsUnchanged`, `test_F01_v2_usdcLegsUnchanged`, `test_F01_v1_fuzz_plainTokenConserves`, `test_F01_v1_fuzz_plainTokenCancelRoundTrips`, `test_F01_v2_fuzz_plainTokenConserves` | 13 pass |
| F-02 | `test_F02_v1_rebaseDownAfterDeposit_cancelReverts` (documents the open behavior) | pass |
| F-03 | `test_F03_v1_blockedEscrow_cancelUsdcOfferReverts`, `test_F03_v1_blockedEscrow_fillReverts`, `test_F03_v1_blockedEscrow_withdrawReverts` | 3 pass |
| F-04 | `test_F04_v2_blockedFeeRecipient_fillReverts`, `test_F04_v2_ownerSetFeeRecipient_restoresFills`, `test_F04_v2_zeroFeeSnapshot_stillFillsWithBlockedRecipient` | 3 pass |
| F-05 | `test_F05_v1_constructor_rejectsZeroAndSelf`, `test_F05_v2_constructor_rejectsZeroAndSelf`, `test_F05_v1_setFeeRecipient_rejectsZeroAndSelf`, `test_F05_v2_setFeeRecipient_rejectsZeroAndSelf` | 4 pass |
| F-06 | `test_F06_v1_fill_makerGaveToken_codeRemoved_reverts`, `test_F06_v1_cancel_makerGaveToken_codeRemoved_reverts`, `test_F06_v2_fill_makerGivesToken_codeRemoved_reverts` | 3 pass |
| F-07 | `test_F07_v1_hugeReturndata_fillAndCancelConsistent`, `test_F07_v2_hugeReturndata_fillConsistent` | 2 pass |
| F-08 | `test_F08_v1_tinyAmount_feeZero`, `test_F08_v2_tinyAmount_feeZero` | 2 pass |
| F-09 | `test_F09_v2_makerRevokesUsdcApproval`, `test_F09_v2_makerRevokesTokenApproval`, `test_F09_v2_makerMovesUsdcBalance`, `test_F09_v2_makerMovesTokenBalance` | 4 pass |
| F-10 | `test_F10_v2_pause_blocksFillAndCreate_cancelWorks`, `test_F10_v1_pause_blocksOnlyCreate_fillAndCancelWork` | 2 pass |
| F-11 | `test_F11_v1_hugeAmountUsdc_fillOverflows_makerCanCancel`, `test_F11_v2_hugeAmountUsdc_fillOverflows_makerCanCancel` | 2 pass |
| F-21, F-22 | `test_F21_F22_v1_setPaused_selector_and_event`, `test_F21_F22_v2_setPaused_selector_and_event` | 2 pass |
| F-12 to F-20, F-23 to F-25 | No dedicated test. They are Slither results. The existing solvency and status invariants (`invariant_usdcSolvent`, `invariant_tokenSolvent`, `invariant_statusOneWay`) pass after the fixes. | n/a |

The F-01 tests for a token that short-pays the recipient on escrow payouts failed on the first fix. They exposed that the v1 payout check watched only the escrow's balance. That gap was fixed and the tests pass.

## 4. Open items

**F-02 (High, open): v1 escrow can come up short for a rebasing token.**
- Risk: if someone escrows a token whose balances shrink on their own after deposit, the contract still owes the original amount. Cancels, fills and withdrawals for that token can then revert or use up other makers' backing. Nobody can be tricked into this, but any offer using such a token is exposed.
- Decision needed: do you want to accept this for the live v1 contract, or approve a behavior change? The options are an owner-managed token allowlist, or share-based accounting. Either changes what tokens can be traded and how the contract works. Retiring v1 in favor of v2, which holds no funds, also removes the risk.

**F-03 (Medium, accepted risk): USDC issuer blocklists the v1 escrow contract.**
- Risk: all USDC in v1 is frozen, including cancels and credit withdrawals, until the issuer lifts it.
- Decision needed: whether you accept this for v1, whether to write an incident procedure with the issuer, and whether to steer users to v2.

**F-04 (Medium, accepted risk): v2 fee recipient blocklisted.**
- Risk: every fill with a fee reverts until the owner calls `setFeeRecipient`. No funds are lost.
- Decision needed: make sure the fee wallet is monitored and the owner keys can respond quickly. A fee-failure bypass would change behavior, so I did not add one.

**F-07 (Low, accepted risk): return-data bomb on token calls.**
- Risk: a hostile token chosen by a maker can burn the taker's gas. It cannot move anyone's funds.
- Decision needed: whether to cap the copied return data in assembly. I left it as is to avoid new assembly in a live contract.

**F-08 (Low, accepted risk): fee rounds to zero on tiny trades.**
- Risk: under about $0.0004 of USDC, no fee is taken.
- Decision needed: whether to round fees up. That changes economics.

**F-09 (Low, accepted risk): v2 offers are not backed by escrow.**
- Risk: makers can over-commit or revoke approvals. Takers waste gas on a failed fill.
- Decision needed: confirm this is the intended trade-off for the non-custodial design.

**F-10 (Low, accepted risk): owner pause powers.**
- Risk: in v2 the owner can stop all fills indefinitely. Makers can still cancel.
- Decision needed: confirm the owner (the Safe) is the right holder of this power.

**F-11 (Informational, accepted risk):** absurdly large `amountUsdc` offers can never be filled but can be cancelled. No action needed unless you want an upper bound.

**F-17 to F-20 (Low or Informational, Slither, accepted risk):** timestamp and low-level-call notes. They are the intended design and need no decision.

**False positives (F-12 to F-16, F-23, F-24):** these Slither results need no decision. The `nonReentrant` guards and the intended exact-amount checks explain them. The third-party auditor may ask about them.

## 5. Audit Provenance

Round 1 (before the fixes):

| Subagent | Dispatched | Files audited | Corpus rules cited |
|---|---|---|---|
| solidity-auditor | yes | 2 | rebasing-and-indexed-token-balance-drift, centralized-stable-blocklist-frozen-vault |
| functional-auditor | yes | 2 | — |

Round 2 (after the fixes, before the last two small edits):

| Subagent | Dispatched | Files audited | Corpus rules cited |
|---|---|---|---|
| solidity-auditor | yes | 2 | none |
| functional-auditor | yes | 2 | — |
