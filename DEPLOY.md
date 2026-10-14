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
   (Remix: "At Address" with the IERC20 / MockToken ABI on `0x3600000000000000000000000000000000000000`.)
3. As **Chord_Deployer**: ChordOTC `createOfferGivingUsdc(CTT, 10000000000000000000, 1000000, 0x0000000000000000000000000000000000000000, 0)`
   → offer 0: 1 USDC for 10 CTT, open to anyone, no expiry.
4. As **Chord_Taker**: CTT `approve(ChordOTC, 10000000000000000000)`.
5. As **Chord_Taker**: ChordOTC `fillOffer(0)`.
6. Check: Chord_Taker received 0.9975 USDC, Chord_Deployer received 10 CTT plus the 0.0025 USDC fee
   (it is also the fee recipient),
   and ChordOTC's USDC and CTT balances are back to 0.
7. Optional: create a second offer and `cancelOffer` it to check the refund.

Send Claude the transaction hashes (or explorer links) and it will check them.
