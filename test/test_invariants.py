"""Randomised invariant test for ChordOTC (stateful fuzzing on an in-process EVM).

Runs many random sequences of create / fill / cancel / withdraw / admin actions, with
USDC-style blocklisting switched on and off for random accounts, expiry time-travel and
fee changes, and checks after EVERY step that:

  I1  escrow solvency: the contract holds exactly (locked amounts of open offers + all
      outstanding credits) of every asset - never more, never less;
  I2  conservation: each account's (wallet balance + claimable credits) matches an
      independent Python model of what the trade rules say it should be, to the unit;
  I3  status machine: offers only move Open -> Filled or Open -> Cancelled, never back;
  I4  no value is created or destroyed: total supply of each asset is unchanged by the
      contract (sum over all holders incl. escrow is constant).

Run:  solc --optimize --optimize-runs 200 --evm-version paris --combined-json abi,bin \
          contracts/ChordOTC.sol test/Mocks.sol > build.json
      python3 test/test_invariants.py build.json [runs] [steps] [seed]
"""
import json, random, sys
from web3 import Web3, EthereumTesterProvider

build = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "build.json"))["contracts"]
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 12
STEPS = int(sys.argv[3]) if len(sys.argv) > 3 else 120
SEED = int(sys.argv[4]) if len(sys.argv) > 4 else 1404

prov = EthereumTesterProvider(); w3 = Web3(prov); T = prov.ethereum_tester
A = w3.eth.accounts
OWNER, FEE = A[0], A[1]
USERS = A[2:7]
ZERO = "0x" + "00" * 20
U, E = 10**6, 10**18

def art(name):
    c = build[name]; abi = c["abi"] if isinstance(c["abi"], list) else json.loads(c["abi"])
    return abi, c["bin"]

def deploy(name, *args):
    abi, bin_ = art(name); C = w3.eth.contract(abi=abi, bytecode=bin_)
    r = w3.eth.wait_for_transaction_receipt(C.constructor(*args).transact({"from": OWNER}))
    return w3.eth.contract(address=r.contractAddress, abi=abi)

def send(fn, sender):
    """Returns True if the transaction succeeded, False if it reverted."""
    try:
        r = w3.eth.wait_for_transaction_receipt(fn.transact({"from": sender, "gas": 2_000_000}))
        return r.status == 1
    except Exception:
        return False

def run(seed):
    rnd = random.Random(seed)
    usdc = deploy("test/Mocks.sol:MockToken", "USD Coin", "USDC", 6)
    tok = deploy("test/Mocks.sol:MockToken", "Test Token", "TT", 18)
    otc = deploy("contracts/ChordOTC.sol:ChordOTC", usdc.address, FEE)
    assets = {"usdc": usdc, "tok": tok}
    holders = USERS + [FEE]
    for who in USERS:
        send(usdc.functions.mint(who, 50_000 * U), OWNER)
        send(tok.functions.mint(who, 50_000 * E), OWNER)
        send(usdc.functions.approve(otc.address, 2**256 - 1), who)
        send(tok.functions.approve(otc.address, 2**256 - 1), who)

    # independent model: what each holder owns (wallet + credit) per asset
    model = {a: {h: assets[a].functions.balanceOf(h).call() for h in holders} for a in assets}
    supply = {a: assets[a].functions.totalSupply().call() for a in assets}
    offers = {}           # id -> dict(maker, taker, usdc, tok, givesUsdc, expires, fee, status)
    fee_bps = 25
    blocked = {a: set() for a in assets}
    counts = {"create": 0, "fill": 0, "cancel": 0, "withdraw": 0, "credited": 0, "rejected": 0}

    def now():
        return w3.eth.get_block("latest").timestamp

    def check_all(step):
        # I1 solvency
        for a, c in assets.items():
            need = sum((o["usdc"] if o["givesUsdc"] else o["tok"]) if a == ("usdc" if o["givesUsdc"] else "tok") else 0
                       for o in offers.values() if o["status"] == 1)
            need += sum(otc.functions.credits(h, c.address).call() for h in holders)
            have = c.functions.balanceOf(otc.address).call()
            assert have == need, f"[seed {seed} step {step}] I1 {a}: escrow has {have}, owes {need}"
        # I2 conservation per holder
        for a, c in assets.items():
            for h in holders:
                actual = c.functions.balanceOf(h).call() + otc.functions.credits(h, c.address).call()
                assert actual == model[a][h], f"[seed {seed} step {step}] I2 {a} {h[:8]}: {actual} != model {model[a][h]}"
        # I3 status machine
        for i, o in offers.items():
            st = otc.functions.getOffer(i).call()[6]
            assert st == o["status"], f"[seed {seed} step {step}] I3 offer {i}: chain {st} != model {o['status']}"
        # I4 supply
        for a, c in assets.items():
            assert c.functions.totalSupply().call() == supply[a], f"I4 {a} supply changed"

    for step in range(STEPS):
        act = rnd.choices(["create", "fill", "cancel", "withdraw", "block", "admin", "time"],
                          weights=[30, 30, 12, 8, 10, 5, 5])[0]
        if act == "create":
            maker = rnd.choice(USERS)
            gives_usdc = rnd.random() < 0.5
            au = rnd.choice([1, 399, 400, 10**6, rnd.randint(1, 5_000 * U)])
            at = rnd.choice([1, rnd.randint(1, 5_000 * E)])
            taker = rnd.choice([ZERO, ZERO, rnd.choice(USERS)])
            exp = rnd.choice([0, 0, now() + rnd.randint(1, 3000)])
            fn = (otc.functions.createOfferGivingUsdc if gives_usdc else otc.functions.createOfferGivingToken)(tok.address, at, au, taker, exp)
            nid = otc.functions.nextOfferId().call()
            if send(fn, maker):
                counts["create"] += 1
                a = "usdc" if gives_usdc else "tok"
                model[a][maker] -= au if gives_usdc else at
                offers[nid] = dict(maker=maker, taker=taker, usdc=au, tok=at, givesUsdc=gives_usdc, expires=exp, fee=fee_bps, status=1)
            else:
                counts["rejected"] += 1
        elif act == "fill" and offers:
            live = [k for k, v in offers.items() if v["status"] == 1]
            i = rnd.choice(live) if live and rnd.random() < 0.85 else rnd.choice(list(offers))
            o = offers[i]
            taker = o["taker"] if o["taker"] != ZERO and rnd.random() < 0.7 else rnd.choice(USERS)
            if send(otc.functions.fillOffer(i), taker):
                assert o["status"] == 1 and o["maker"] != taker and o["taker"] in (ZERO, taker)
                assert o["expires"] == 0 or now() <= o["expires"]
                fee = o["usdc"] * o["fee"] // 10_000
                if o["givesUsdc"]:
                    model["tok"][taker] -= o["tok"]; model["tok"][o["maker"]] += o["tok"]
                    model["usdc"][taker] += o["usdc"] - fee
                else:
                    model["usdc"][taker] -= o["usdc"]; model["usdc"][o["maker"]] += o["usdc"] - fee
                    model["tok"][taker] += o["tok"]
                model["usdc"][FEE] += fee
                o["status"] = 2; counts["fill"] += 1
            else:
                counts["rejected"] += 1
        elif act == "cancel" and offers:
            live = [k for k, v in offers.items() if v["status"] == 1]
            i = rnd.choice(live) if live and rnd.random() < 0.85 else rnd.choice(list(offers)); o = offers[i]
            who = o["maker"] if rnd.random() < 0.8 else rnd.choice(USERS)
            if send(otc.functions.cancelOffer(i), who):
                assert o["status"] == 1 and who == o["maker"]
                a = "usdc" if o["givesUsdc"] else "tok"
                model[a][who] += o["usdc"] if o["givesUsdc"] else o["tok"]
                o["status"] = 3; counts["cancel"] += 1
            else:
                counts["rejected"] += 1
        elif act == "withdraw":
            owed = [(h, a) for h in holders for a in assets if otc.functions.credits(h, assets[a].address).call() > 0]
            who, a = rnd.choice(owed) if owed and rnd.random() < 0.8 else (rnd.choice(holders), rnd.choice(list(assets)))
            if send(otc.functions.withdraw(assets[a].address), who):
                counts["withdraw"] += 1      # model unchanged: credit just moves into the wallet
        elif act == "block":
            a = rnd.choice(list(assets)); who = rnd.choice(holders)
            on = who not in blocked[a]
            send(assets[a].functions.setBlocked(who, on), OWNER)
            (blocked[a].add if on else blocked[a].discard)(who)
        elif act == "admin":
            r = rnd.random()
            if r < 0.5:
                nb = rnd.choice([0, 25, 100, 300, 301, 5000])
                if send(otc.functions.setFeeBps(nb), OWNER): fee_bps = nb
                else: assert nb > 300
            elif r < 0.8:
                send(otc.functions.setPaused(rnd.random() < 0.3), OWNER)
            else:
                assert not send(otc.functions.setFeeBps(10), rnd.choice(USERS)), "non-owner changed fee"
        elif act == "time":
            T.time_travel(now() + rnd.randint(1, 2000)); T.mine_blocks(1)
        check_all(step)

    counts["credited"] = sum(1 for h in holders for c in assets.values() if otc.functions.credits(h, c.address).call() > 0)
    return counts

totals = {}
for r in range(RUNS):
    c = run(SEED + r)
    for k, v in c.items(): totals[k] = totals.get(k, 0) + v
print(f"invariants held across {RUNS} runs x {STEPS} steps: " + ", ".join(f"{k}={v}" for k, v in totals.items()))
