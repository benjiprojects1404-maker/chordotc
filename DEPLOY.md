# Deploying ChordOTC to Arc Testnet (Remix + MetaMask)

You deploy from your own wallet in Remix. No keys or seed phrases leave MetaMask.

## Network

| | |
|---|---|
| Network | Arc Testnet |
| Chain ID | 5042002 |
| RPC | https://rpc.testnet.arc.io |
| Explorer | https://explorer.testnet.arc.io |
| USDC (ERC-20, 6 decimals) | `0x3600000000000000000000000000000000000000` |

Gas is paid in USDC. The minimum gas price is 20 gwei; MetaMask normally picks this up from the RPC.
If a transaction sits pending for a long time, check the gas price is at least 20 gwei.

## 1. Load the files into Remix

1. Open https://remix.ethereum.org
2. File explorer → "Import from GitHub/URL" (or the GitHub icon), and import:
   - `https://github.com/benjiprojects1404-maker/chordotc/blob/main/contracts/ChordOTC.sol`
   - `https://github.com/benjiprojects1404-maker/chordotc/blob/main/test/Mocks.sol`

## 2. Compile (both files)

Solidity compiler tab → Advanced configurations:

- Compiler: **0.8.24**
- Optimization: **on, 200 runs**
- EVM version: **paris**

These are the settings the tests ran with, and they make explorer verification match later.

## 3. Deploy

Deploy & run tab → Environment: **Injected Provider – MetaMask**, account **Chord_Deployer**,
network Arc Testnet (Remix shows "Custom (5042002)").

**a) ChordOTC**
- `_usdc`: `0x3600000000000000000000000000000000000000`
- `_feeRecipient`: your Chord_Deployer address (fine for testnet; change later with `setFeeRecipient`)

**b) Test token** (MockToken from Mocks.sol, testnet only: anyone can mint it)
- `_n`: `Chord Test Token`, `_s`: `CTT`, `_d`: `18`

Copy both deployed addresses and send them to Claude.

## 4. Smoke test

A maker cannot fill their own offer, so you need a second MetaMask account
(e.g. "Chord_Taker") with a little USDC for gas (send ~3 USDC from Chord_Deployer).

Amounts: USDC uses 6 decimals (1 USDC = `1000000`); CTT uses 18 (1 CTT = `1000000000000000000`).

1. CTT `mint`: to = Chord_Taker, amount = `100000000000000000000` (100 CTT).
2. As **Chord_Deployer**: USDC at `0x36000…0000` → `approve(ChordOTC, 1000000)`.
   (Remix 2.6+: Deployed Contracts → "+ Add Contract", paste `0x3600000000000000000000000000000000000000`
   and pick the MockToken ABI. Remix will label it MockToken; it is USDC.)
3. As **Chord_Deployer**: ChordOTC `createOfferGivingUsdc(CTT, 10000000000000000000, 1000000, 0x0000000000000000000000000000000000000000, 0)`
   → offer **1** (IDs start at 1): 1 USDC for 10 CTT, open to anyone, no expiry.
4. As **Chord_Taker**: CTT `approve(ChordOTC, 10000000000000000000)`.
5. As **Chord_Taker**: ChordOTC `fillOffer(1)`.
6. Check: Chord_Taker received 0.9975 USDC, Chord_Deployer received 10 CTT plus the 0.0025 USDC fee
   (it is also the fee recipient),
   and ChordOTC's USDC and CTT balances are back to 0.
7. Optional: create a second offer and `cancelOffer` it to check the refund.

Use `createOfferGivingUsdc`, not `createOfferGivingToken` (the maker has no CTT, so that one reverts
with "token transferFrom failed").

Send Claude the transaction hashes (or explorer links) and it will check them.

## Testnet deployment (14 Oct 2026)

| | Address |
|---|---|
| ChordOTC | `0x7d56c055D844BBdEaD5BEf5cDf3aD9c796849c2c` |
| Chord Test Token (CTT) | `0x112a05D335c36881887568Ce924CcaEB0c52F097` |
| Deployer / owner / fee recipient | `0xBE7ee8E66082d81Ec9Ae5C4E30D29A44eDaB3AE7` |

Smoke test passed: offer #1 (1 USDC for 10 CTT) created in tx `0xe39c7746…c149` and filled in
`0x241e1f59…46d3`. The taker received 997,500 (0.9975 USDC), the fee wallet 2,500 (0.0025 USDC),
the escrow's USDC balance returned to 0, and no payouts had to be credited.
Arc also emits an 18-decimal native `Transfer` alongside each 6-decimal USDC `Transfer`, as documented.
