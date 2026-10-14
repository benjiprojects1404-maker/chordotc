# ChordOTC: internal security review

| | |
|---|---|
| Contract | `contracts/ChordOTC.sol` (380 lines, Solidity 0.8.24, no external libraries) |
| Deployment reviewed | Arc testnet `0x7d56c055D844BBdEaD5BEf5cDf3aD9c796849c2c` (source verified on the explorer) |
| Date | 14 October 2026 |
| Type | Internal review by the developer with AI assistance. **Not an independent audit.** |

## Summary

No critical, high or medium issues were found in the contract. Funds can only leave the escrow to:

- the maker who locked them (cancel),
- the two counterparties of a fill,
- the fee wallet,
- or the account a failed payout was credited to.

The owner has no path to any user's funds.

One medium issue was found in the **web app**, not the contract: tokens that imitate a stablecoin's name. It is fixed in the same change as this review. The remaining findings are low or informational and are either accepted by design or noted for the mainnet beta.

| ID | Title | Severity | Status |
|---|---|---|---|
| UI-1 | Any token can call itself "USDC" in the offers table | Medium (front end) | Fixed |
| L-1 | Maker blocklisted by USDC/the token cannot cancel until unblocked | Low | Accepted (by design) |
| L-2 | A malicious token can make fills of its own offers revert or misbehave | Low | Accepted (scoped to that token) |
| L-3 | Per-offer cap limits only the locked side | Low | Accepted, documented |
| I-1 | Fee rounds down; dust-sized trades pay no fee | Info | Accepted |
| I-2 | Fixed-price offers can go stale; cancel races fill | Info | Inherent to OTC |
| I-3 | Gas-limited fill cannot force payouts into credits | Info | Checked, not exploitable |
| I-4 | Owner powers are limited but should sit behind a multisig for mainnet | Info | Mainnet checklist |

## Scope and method

1. **Manual line-by-line review** of every external function, every place funds move and every privileged function, against the Arc-specific risks listed in the contract header:
   - 6-decimal USDC (ERC-20) vs 18-decimal native USDC,
   - the USDC blocklist,
   - no value transfers to `address(0)`,
   - non-strictly-increasing timestamps.
2. **Unit tests** (`test/test_chordotc.py`, 43 checks): both offer directions, private takers, expiry, cancel and refund, fee snapshot, blocklisted maker, blocklisted fee wallet, fee-on-transfer rejection, pause, caps, two-step ownership, and an escrow-solvency check after every scenario.
3. **Stateful fuzzing** (`test/test_invariants.py`, new): thousands of random create, fill, cancel, withdraw, fee-change, pause and time-travel actions, with USDC-style blocklisting switched on and off for random accounts. After **every** step it checks:
   - **I1, solvency:** the escrow holds exactly the open offers' locked amounts plus all outstanding credits, never more and never less.
   - **I2, conservation:** every account's wallet balance plus claimable credit matches an independent model of the trade rules, to the smallest unit.
   - **I3:** offers only ever move Open → Filled or Open → Cancelled.
   - **I4:** the contract never creates or destroys tokens.
   - **Result:** 10 independent runs of 150 steps each (1,500 random actions in total), covering 239 offers created, 82 filled and 84 cancelled. In 13 cases, a counterparty or fee payout went to a blocklisted address and was credited instead. Hundreds of invalid actions were correctly rejected. **All four invariants held after every step.**
4. **Live testnet run:** an offer was created and filled on Arc testnet. The 0.9975 USDC to the taker, the 0.0025 USDC fee and the escrow returning to zero were all confirmed from on-chain transfer logs.
5. **Static analysis** (Slither, low severity and above): 7 results, all reviewed and expected:
   - **Reentrancy (2):** every caller is `nonReentrant`, and offer status is updated before any external call.
   - **Strict equality (1):** this is the intended exact balance-delta check that rejects fee-on-transfer tokens.
   - **Timestamp comparisons (4):** offer expiry, by design and safe with repeated timestamps.

## Findings

### UI-1: Any token can call itself "USDC" in the offers table (Medium, front end, fixed)

**Problem:** ERC-20 names and symbols are not unique. Anyone can deploy a token whose `symbol()` is `USDC` and post an offer giving that token. The offers table read the symbol from the token, so the offer appeared as "Sell USDC", inviting a taker to pay real USDC for a worthless token.

The contract itself is not affected. Its USDC address is fixed at deployment, and the "token" side of an offer can never be the real USDC.

**Fix (site):**
- **Token list:** the desk now keeps a list of known tokens by address.
- **"Unlisted" tag:** any token not on the list is shown with an *unlisted* tag.
- **"Imitation?" warning:** an unlisted token whose symbol looks like a stablecoin (USD, USDT, EUR and so on) gets a red *imitation?* tag, a warning under the create form, and a confirmation step before Fill that shows the token's contract address.

**Testing:** covered by the browser test. A fake "USDC" offer is flagged, and dismissing the warning leaves the offer unfilled.

### L-1: A blocklisted maker cannot cancel until unblocked (Low, by design)

**Problem:** `cancelOffer` refunds directly to the maker. If the maker is on USDC's blocklist (or the token's), the refund reverts and the locked funds stay in escrow until they are unblocked.

**Why it is accepted:**
- Crediting the refund would not help, since `withdraw` also pays only the credited address.
- Redirecting the refund to another address would bypass the issuer's blocklist, which the contract deliberately refuses to do.

Other users are unaffected: fills to that maker still settle, because the maker's proceeds are credited rather than reverting.

### L-2: A malicious token can break fills of its own offers (Low, scoped)

**Problem:** the token leg is called with low-level calls. A hostile token could revert, return malformed data, return a very large payload to waste gas, or report balances that don't match its transfers. The worst outcome is that offers *in that token* cannot be filled, or that a fill reverts.

**Protections already in place:**
- **Rejects fake transfers:** `_pullExact` checks that the escrow's balance rose by exactly the amount pulled, so fee-on-transfer and rebasing tokens are rejected and a token cannot pretend it was paid.
- **No reentry:** every state-changing function is `nonReentrant`.
- **Isolation:** other tokens' offers and USDC balances are kept separate.

**User guidance:** the remaining risk is "you traded a bad token", which is covered by UI-1's warnings and the unlisted tag.

### L-3: The per-offer cap limits only the locked side (Low, documented)

`maxOfferAmount[asset]` caps how much a maker can lock into one offer: USDC for give-USDC offers, the token for give-token offers. The USDC a taker pays into a give-token offer passes straight through to the maker in the same transaction and is not capped. This matches the cap's purpose, which is to limit funds held in escrow during the beta.

### I-1: Fee rounds down

`fee = amountUsdc * feeBps / 10_000` rounds down, so offers under 400 USDC units (0.0004 USDC) at 0.25% pay no fee. Gas makes splitting trades to avoid fees pointless. Accepted.

### I-2: Fixed-price offers can go stale; cancel and fill can race

**Problem:** an offer is a fixed price, so if the market moves, an open offer can become a free option for takers. A maker's cancel and a taker's fill submitted at the same time are settled by block order.

**Mitigations:** makers can use the optional expiry or a private taker. The UI defaults to "never expires" with a clear cancel button.

### I-3: A gas-limited fill cannot force payouts into credits (checked)

**The concern:** a payout that fails is credited instead of reverting. Could a taker set a precise gas limit so the inner transfer runs out of gas while the outer fill succeeds, pushing the maker into an extra `withdraw` step?

**Why it can't happen:** under the 63/64 rule, the remaining 1/64 of gas is far below what the rest of `fillOffer` needs (another token transfer, storage writes and events). The whole fill reverts instead. Not exploitable.

### I-4: Owner powers (mainnet checklist)

**What the owner can do:**
- change the fee (max 3%, new offers only, since the fee is snapshotted per offer),
- change the fee wallet,
- pause **new** offers (fills and cancels always work),
- set per-offer caps,
- transfer ownership (two-step).

**What the owner cannot do:**
- move, freeze or redirect any open offer, credit or user balance.

**Before mainnet:** put ownership and the fee wallet behind a multisig (Safe), and publish the owner address.

## Arc-specific checks

| Risk | Result |
|---|---|
| Mixing native 18-decimal USDC with 6-decimal ERC-20 USDC | Nothing is `payable` and there is no `receive`/`fallback`, so native value cannot enter the contract. All USDC goes through `transfer`/`transferFrom`. ✓ |
| USDC blocklist | Counterparty and fee payouts that fail are credited, not reverted. Credits are only claimable by the credited address. Covered by unit and fuzz tests. ✓ |
| Value transfer to `address(0)` | Never attempted. The fee wallet, owner and USDC address are checked to be non-zero. ✓ |
| Repeated or equal block timestamps | Expiry uses `block.timestamp <= expiresAt`, so it is safe when timestamps repeat. Creation requires `expiresAt > now`. Nothing else depends on time. ✓ |
| 20 gwei minimum gas price | An operational matter for the wallet and app. Nothing in the contract depends on it. ✓ |

## Recommendations before mainnet

1. Ownership and fee wallet behind a multisig; publish the addresses.
2. Conservative per-offer caps for USDC and each listed token during the beta, raised step by step.
3. Keep the site's token list short (USDC pairs with tokens the desk has checked).
4. An independent audit before caps are raised beyond beta levels.
5. Re-run `test_chordotc.py` and `test_invariants.py` on any contract change.
