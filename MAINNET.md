# ChordOTC: Arc mainnet launch checklist

## Live deployment (14 Oct 2026)

| | Address |
|---|---|
| ChordOTC (verified) | `0x112a05D335c36881887568Ce924CcaEB0c52F097` |
| Owner and fee wallet: ChordOTC Treasury Safe (2 of 2) | `0xc3FC2A5D1E7e2F5d597bE891e4BC36F117D9d4B6` |
| Deployer | `0xBE7ee8E66082d81Ec9Ae5C4E30D29A44eDaB3AE7` |

- **Beta caps per offer:** 100 USDC, 100 EURC, 0.05 WETH, 0.002 cirBTC.
- **Fee:** 0.25%.
- **Ownership:** accepted by the Safe on 14 Oct 2026 (Safe transaction nonce 0).

The mainnet ChordOTC has the same address as the testnet test token (CTT). Same deployer, same transaction count on both chains, so this is a coincidence and harmless.


Network: **Arc mainnet**.

| Setting | Value |
|---|---|
| Chain ID | `5042` |
| RPC | `https://rpc.mainnet.arc.io` |
| Explorer | `https://explorer.arc.io` |
| Gas | USDC; minimum gas price 20 gwei |

| Token | Address | Decimals |
|---|---|---|
| USDC (ERC-20 interface) | `0x3600000000000000000000000000000000000000` | 6 |
| EURC | `0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1` | 6 |
| WETH | `0x128cC466B61f542da60c70e3aA11c10e19B84EDB` | 18 |
| cirBTC | `0x171A4217b86A807A64eB94757Db6849fb4bDbAA0` | 8 |
| LINK (Chainlink) | `0x76a443768A5e3B8d1AED0105FC250877841Deb40` | 18 |
| VIRTUAL (Virtuals Protocol) | `0x8C4252c87081c88c6Ad57d6dD97E1cAFebF842B7` | 18 |
| ARGUS (Argus) | `0xeCe5cA8bf9220718E5727754026757512212cb3c` | 18 |
| ARCUS (Arcus Network) | `0xB7C934FF18730c24e6113BB4bC5A68feEf16fD29` | 18 |

LINK, VIRTUAL, ARGUS and ARCUS were added to the site's listed tokens on 21 Oct 2026. Each is the explorer's admin-verified entry for that name; Arc has several look-alike contracts using the same names, so always go by address. ARGUS and ARCUS are Argus launchpad tokens with a buy/sell tax on their pools. Recent wallet-to-wallet transfers showed no tax, so escrow transfers should work. If a tax ever applied to a plain transfer, ChordOTC's balance check would reject the offer rather than settle short.

Budget: about **10 USDC** in Chord_Deployer and **2–3 USDC** in Chord_Taker. Deployment costs about 0.05 USDC.

---

## 1. Create the multisig (Safe)

Safe officially supports Arc mainnet (chain 5042).

1. Open https://app.safe.global, connect MetaMask, pick network **Arc**, then **Create account**.
2. Owners: at least two wallets you control on **separate devices or seed phrases**, for example a hardware wallet plus a second MetaMask. Threshold: **2 of 2**, or 2 of 3 if you add a backup owner.
3. Note the Safe address. It becomes the contract **owner** and the **fee wallet**.

## 2. Deploy ChordOTC (Remix + MetaMask, as on testnet)

1. Switch MetaMask to **Arc** (mainnet) on **Chord_Deployer**.
2. In Remix, compile `contracts/ChordOTC.sol` with **0.8.24**, optimization **200**, EVM **paris**.
3. Deploy with:
   - `_usdc`: `0x3600000000000000000000000000000000000000`
   - `_feeRecipient`: **the Safe address**
4. Send Claude the contract address. Claude verifies it on explorer.arc.io and checks the constructor arguments.

## 3. Beta limits (from Chord_Deployer, before handing ownership over)

`setMaxOfferAmount(asset, cap)` caps how much can be locked in one offer. Suggested beta caps:

| Asset | Cap | Value to enter |
|---|---|---|
| USDC | 100 USDC | `100000000` |
| EURC | 100 EURC | `100000000` |
| WETH | 0.05 WETH | `50000000000000000` |
| cirBTC | 0.002 cirBTC | `200000` |

Added 21 Oct 2026 (about 100 USDC each at the time; set from the Safe with `setMaxOfferAmount`):

| Asset | Cap | Value to enter |
|---|---|---|
| LINK | 8 LINK | `8000000000000000000` |
| VIRTUAL | 150 VIRTUAL | `150000000000000000000` |
| ARGUS | 13,500 ARGUS | `13500000000000000000000` |
| ARCUS | 2,000,000 ARCUS | `2000000000000000000000000` |

These can be raised later, from the Safe, as confidence grows.

## 4. Hand ownership to the Safe

1. Chord_Deployer: `transferOwnership(<Safe address>)`.
2. In the Safe, go to **New transaction → Transaction Builder**. Enter the ChordOTC address, paste the ABI (or let it load from the verified contract), choose `acceptOwnership()`, then sign with 2 owners and execute.
3. Check `owner()` on the explorer: it must show the Safe address.

## 5. Smoke test with real tokens

**Create and cancel (needs only USDC):**
1. Chord_Deployer: create an offer giving **1 USDC** for some EURC.
2. Cancel it, and check the 1 USDC came back.

**Full fill (needs a little EURC in Chord_Taker):**
1. Get about 2 EURC into Chord_Taker, for example by swapping on an Arc DEX or bridging EURC from Base.
2. Chord_Deployer: offer **1 USDC** for an EURC amount near the market rate.
3. Chord_Taker: fill it.
4. Check that the taker got 0.9975 USDC, the maker got the EURC, and the Safe received the 0.0025 USDC fee.

## 6. Switch the site on

1. In `site/index.html`, set `NETS.mainnet.otc` to the deployed address. The site then defaults to mainnet, shows the **Mainnet beta** banner, and keeps testnet one click away (`?net=testnet`).
2. Merge. Cloudflare redeploys chordotc.com in about a minute.
3. Update `SECURITY_REVIEW.md` and the README with the mainnet address, Safe address and caps.

## Before raising caps

- An independent audit.
- Re-run `test/test_chordotc.py` and `test/test_invariants.py` on any contract change.
