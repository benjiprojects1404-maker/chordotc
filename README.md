# ChordOTC

Peer-to-peer OTC escrow for ERC-20 token <-> USDC trades on Arc (Circle's L1).
Derived from Handshake OTCEscrow v3 (BlockDAG chain 1404), adapted for Arc:

- USDC handled only through its 6-decimal ERC-20 interface; nothing is payable.
- Payouts to a maker or fee wallet that fail (e.g. USDC blocklist) are credited and claimable
  by that address only, so one blocked party cannot stop a fill.
- Optional per-offer expiry, compared with `>` only (Arc timestamps can repeat).
- Two-step ownership; fee snapshotted per offer and capped at 3%; per-asset caps; pause for new offers.

## Deployments

| Network | ChordOTC | Owner / fee wallet |
|---|---|---|
| Arc mainnet (5042), beta | `0x112a05D335c36881887568Ce924CcaEB0c52F097` | Safe `0xc3FC2A5D1E7e2F5d597bE891e4BC36F117D9d4B6` (2 of 2) |
| Arc testnet (5042002) | `0x7d56c055D844BBdEaD5BEf5cDf3aD9c796849c2c` | deployer |

App: https://chordotc.com (mainnet beta; testnet at https://chordotc.com/?net=testnet). Launch checklist: [MAINNET.md](MAINNET.md).

## Test

```
solc --optimize --optimize-runs 200 --evm-version paris --combined-json abi,bin \
  contracts/ChordOTC.sol test/Mocks.sol > build.json
python3 test/test_chordotc.py build.json   # needs: pip install "eth-tester[py-evm]" web3
```

43 checks, including a blocklisted maker, a blocklisted fee wallet, expiry, fee-on-transfer
rejection and an escrow-balance check after every scenario.

Stateful fuzzing (random create/fill/cancel/withdraw/admin/time-travel with blocklisting), checking
escrow solvency and per-account conservation after every step:

```
python3 test/test_invariants.py build.json [runs] [steps] [seed]
```

See [SECURITY_REVIEW.md](SECURITY_REVIEW.md) for the internal review.

## Status and reporting a vulnerability

ChordOTC has **not been independently audited**. The contract is verified on Arc mainnet.
The internal review is an AI-assisted check, not an audit.

Please report vulnerabilities privately to **benjamin@chordotc.com** before disclosing them
publicly, particularly anything that could affect funds on the live contract. Reviewers who
report valid issues will be credited here if they wish.

## Foundry tests (stateful fuzzing and edge cases)

Second, independent test harness alongside the Python suite. Same properties, different fuzzer.

Setup (once):

```
curl -L https://foundry.paradigm.xyz | bash && foundryup
git submodule update --init          # fetches forge-std (pinned in foundry.lock)
```

Run:

```
forge test                              # edge cases + invariants (256 runs)
forge test --profile ci                 # 1,000 runs, depth 200
```

Fork tests against Arc mainnet (live ChordOTC, real USDC and EURC; nothing is sent):

```
forge test --match-contract ChordOTCForkTest --fork-url https://rpc.mainnet.arc.io -vv
```

Arc's blocklist and native-transfer precompiles only exist in Arc's node, so the fork tests put
small stand-ins at those addresses (see the top of `test/foundry/ChordOTC.fork.t.sol`).

Invariants: USDC and token solvency (escrow balance = locked + credits owed) and one-way offer status.
Edge cases: blocklisted maker or fee wallet cannot block a fill, fee-on-transfer tokens rejected,
expired offers can't be filled but can be cancelled, private offers, fee snapshot at creation.
