# ChordOTC

Peer-to-peer OTC escrow for ERC-20 token <-> USDC trades on Arc (Circle's L1).
Derived from Handshake OTCEscrow v3 (BlockDAG chain 1404), adapted for Arc:

- USDC handled only through its 6-decimal ERC-20 interface; nothing is payable.
- Payouts to a maker or fee wallet that fail (e.g. USDC blocklist) are credited and claimable
  by that address only, so one blocked party cannot stop a fill.
- Optional per-offer expiry, compared with `>` only (Arc timestamps can repeat).
- Two-step ownership; fee snapshotted per offer and capped at 3%; per-asset caps; pause for new offers.

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
