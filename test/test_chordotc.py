"""ChordOTC test suite on an in-process EVM (eth-tester / py-evm).

Run:  solc --optimize --optimize-runs 200 --evm-version paris --combined-json abi,bin \
          contracts/ChordOTC.sol test/Mocks.sol > build.json
      python3 test/test_chordotc.py build.json
"""
import json, sys
from web3 import Web3, EthereumTesterProvider
from eth_tester.exceptions import TransactionFailed

build = json.load(open(sys.argv[1] if len(sys.argv) > 1 else "build.json"))["contracts"]
def art(name):
    c = build[name]; abi = c["abi"] if isinstance(c["abi"], list) else json.loads(c["abi"])
    return abi, c["bin"]

prov = EthereumTesterProvider(); w3 = Web3(prov); T = prov.ethereum_tester
A = w3.eth.accounts
OWNER, FEE, MAKER, TAKER, OTHER = A[0], A[1], A[2], A[3], A[4]

def deploy(name, *args, sender=OWNER):
    abi, bin_ = art(name); C = w3.eth.contract(abi=abi, bytecode=bin_)
    r = w3.eth.wait_for_transaction_receipt(C.constructor(*args).transact({"from": sender}))
    return w3.eth.contract(address=r.contractAddress, abi=abi)

def tx(fn, sender, value=0):
    return w3.eth.wait_for_transaction_receipt(fn.transact({"from": sender, "value": value}))

def reverts(fn, sender, msg=None, value=0):
    try:
        fn.transact({"from": sender, "value": value})
    except (TransactionFailed, Exception) as e:
        if msg and msg not in str(e):
            raise AssertionError(f"reverted with {e!r}, expected {msg!r}")
        return True
    raise AssertionError("expected revert")

U = 10**6       # USDC, 6 decimals
E = 10**18      # token, 18 decimals
passed = []
def check(name, cond):
    assert cond, name
    passed.append(name)

def fresh():
    usdc = deploy("test/Mocks.sol:MockToken", "USD Coin", "USDC", 6)
    tok = deploy("test/Mocks.sol:MockToken", "Test Token", "TT", 18)
    otc = deploy("contracts/ChordOTC.sol:ChordOTC", usdc.address, FEE)
    for who in (MAKER, TAKER, OTHER):
        tx(usdc.functions.mint(who, 1_000_000 * U), OWNER)
        tx(tok.functions.mint(who, 1_000_000 * E), OWNER)
        tx(usdc.functions.approve(otc.address, 2**256 - 1), who)
        tx(tok.functions.approve(otc.address, 2**256 - 1), who)
    return usdc, tok, otc

def held_ok(usdc, tok, otc):
    """Escrow holds exactly the open offers' locked amounts plus outstanding credits."""
    n = otc.functions.totalOffers().call()
    need_u = need_t = 0
    for i in range(1, n + 1):
        o = otc.functions.getOffer(i).call()
        if o[6] == 1:  # Open
            if o[5]: need_u += o[3]
            else: need_t += o[4]
    for who in (MAKER, TAKER, OTHER, FEE):
        need_u += otc.functions.credits(who, usdc.address).call()
        need_t += otc.functions.credits(who, tok.address).call()
    return usdc.functions.balanceOf(otc.address).call() == need_u and tok.functions.balanceOf(otc.address).call() == need_t

# 1. maker gives USDC, taker pays token
usdc, tok, otc = fresh()
tx(otc.functions.createOfferGivingUsdc(tok.address, 500 * E, 1000 * U, Web3.to_checksum_address("0x" + "00" * 20), 0), MAKER)
mu, mt = usdc.functions.balanceOf(MAKER).call(), tok.functions.balanceOf(MAKER).call()
tu = usdc.functions.balanceOf(TAKER).call()
tx(otc.functions.fillOffer(1), TAKER)
check("usdc offer: maker receives token", tok.functions.balanceOf(MAKER).call() == mt + 500 * E)
check("usdc offer: taker receives USDC minus 0.25% fee", usdc.functions.balanceOf(TAKER).call() == tu + 1000 * U - 2_500_000)
check("usdc offer: fee recipient paid 2.5 USDC", usdc.functions.balanceOf(FEE).call() == 2_500_000)
check("usdc offer: escrow empty after fill", held_ok(usdc, tok, otc) and usdc.functions.balanceOf(otc.address).call() == 0)
check("filled offer cannot be filled again", reverts(otc.functions.fillOffer(1), OTHER, "not open"))

# 2. maker gives token, taker pays USDC
tx(otc.functions.createOfferGivingToken(tok.address, 200 * E, 400 * U, "0x" + "00" * 20, 0), MAKER)
mu = usdc.functions.balanceOf(MAKER).call(); tt = tok.functions.balanceOf(TAKER).call()
tx(otc.functions.fillOffer(2), TAKER)
check("token offer: maker receives USDC minus fee", usdc.functions.balanceOf(MAKER).call() == mu + 400 * U - 1 * U)
check("token offer: taker receives token", tok.functions.balanceOf(TAKER).call() == tt + 200 * E)
check("token offer: escrow balanced", held_ok(usdc, tok, otc))

# 3. cancel refunds in full; only maker can cancel
tx(otc.functions.createOfferGivingUsdc(tok.address, 1 * E, 50 * U, "0x" + "00" * 20, 0), MAKER)
check("non-maker cannot cancel", reverts(otc.functions.cancelOffer(3), TAKER, "not your offer"))
mu = usdc.functions.balanceOf(MAKER).call(); tx(otc.functions.cancelOffer(3), MAKER)
check("cancel refunds full USDC", usdc.functions.balanceOf(MAKER).call() == mu + 50 * U)
check("cancelled offer cannot be filled", reverts(otc.functions.fillOffer(3), TAKER, "not open"))

# 4. private offer
tx(otc.functions.createOfferGivingToken(tok.address, 1 * E, 10 * U, TAKER, 0), MAKER)
check("private offer rejects other takers", reverts(otc.functions.fillOffer(4), OTHER, "not your offer to fill"))
tx(otc.functions.fillOffer(4), TAKER); check("private offer fillable by named taker", otc.functions.getOffer(4).call()[6] == 2)

# 5. expiry (Arc timestamps can repeat; compare with > only)
now = w3.eth.get_block("latest")["timestamp"]
tx(otc.functions.createOfferGivingUsdc(tok.address, 1 * E, 10 * U, "0x" + "00" * 20, now + 100), MAKER)
check("isFillable before expiry", otc.functions.isFillable(5).call())
T.time_travel(now + 200); T.mine_blocks(1)
check("expired offer cannot be filled", reverts(otc.functions.fillOffer(5), TAKER, "offer expired"))
check("isFillable false after expiry", not otc.functions.isFillable(5).call())
mu = usdc.functions.balanceOf(MAKER).call(); tx(otc.functions.cancelOffer(5), MAKER)
check("expired offer can still be cancelled", usdc.functions.balanceOf(MAKER).call() == mu + 10 * U)
now = w3.eth.get_block("latest")["timestamp"]
check("expiry in the past rejected", reverts(otc.functions.createOfferGivingUsdc(tok.address, 1 * E, 1 * U, "0x" + "00" * 20, now - 1), MAKER, "expiry in the past"))

# 6. USDC-blocklisted maker cannot block a fill; payout credited, withdrawable only by maker once unblocked
usdc, tok, otc = fresh()
tx(otc.functions.createOfferGivingToken(tok.address, 10 * E, 100 * U, "0x" + "00" * 20, 0), MAKER)
tx(usdc.functions.setBlocked(MAKER, True), OWNER)
tx(otc.functions.fillOffer(1), TAKER)
check("blocklisted maker: fill still succeeds", otc.functions.getOffer(1).call()[6] == 2)
check("blocklisted maker: USDC credited", otc.functions.credits(MAKER, usdc.address).call() == 100 * U - 250_000)
check("blocklisted maker: escrow balanced", held_ok(usdc, tok, otc))
check("blocklisted maker cannot withdraw while blocked", reverts(otc.functions.withdraw(usdc.address), MAKER))
check("others cannot withdraw maker's credit", reverts(otc.functions.withdraw(usdc.address), OTHER, "nothing to withdraw"))
tx(usdc.functions.setBlocked(MAKER, False), OWNER)
mu = usdc.functions.balanceOf(MAKER).call(); tx(otc.functions.withdraw(usdc.address), MAKER)
check("maker withdraws credit after unblock", usdc.functions.balanceOf(MAKER).call() == mu + 100 * U - 250_000)
check("credit cleared, escrow empty", held_ok(usdc, tok, otc) and usdc.functions.balanceOf(otc.address).call() == 0)

# 7. blocklisted fee wallet cannot block trading
tx(usdc.functions.setBlocked(FEE, True), OWNER)
tx(otc.functions.createOfferGivingUsdc(tok.address, 1 * E, 100 * U, "0x" + "00" * 20, 0), MAKER)
tx(otc.functions.fillOffer(2), TAKER)
check("blocklisted fee wallet: fill succeeds, fee credited", otc.functions.credits(FEE, usdc.address).call() == 250_000)
check("blocklisted fee wallet: escrow balanced", held_ok(usdc, tok, otc))

# 8. creation guards
usdc, tok, otc = fresh()
fot = deploy("test/Mocks.sol:MockToken", "Fee Token", "FOT", 18)
tx(fot.functions.mint(MAKER, 100 * E), OWNER); tx(fot.functions.approve(otc.address, 2**256 - 1), MAKER); tx(fot.functions.setFeeBps(100), OWNER)
check("fee-on-transfer token rejected", reverts(otc.functions.createOfferGivingToken(fot.address, 10 * E, 1 * U, "0x" + "00" * 20, 0), MAKER, "transfer fee"))
check("USDC as the 'token' rejected", reverts(otc.functions.createOfferGivingToken(usdc.address, 1 * U, 1 * U, "0x" + "00" * 20, 0), MAKER, "bad token"))
check("no-code token rejected", reverts(otc.functions.createOfferGivingUsdc(OTHER, 1, 1 * U, "0x" + "00" * 20, 0), MAKER, "token has no code"))
check("zero amounts rejected", reverts(otc.functions.createOfferGivingUsdc(tok.address, 0, 1 * U, "0x" + "00" * 20, 0), MAKER, "amountToken = 0"))
check("maker as taker rejected", reverts(otc.functions.createOfferGivingUsdc(tok.address, 1, 1 * U, MAKER, 0), MAKER, "taker is maker"))
tx(otc.functions.createOfferGivingUsdc(tok.address, 1 * E, 1 * U, "0x" + "00" * 20, 0), MAKER)
check("maker cannot fill own open offer", reverts(otc.functions.fillOffer(1), MAKER, "cannot fill own offer"))

# 9. fee snapshot, cap, pause, native value
tx(otc.functions.setFeeBps(300), OWNER)
tu = usdc.functions.balanceOf(TAKER).call(); tx(otc.functions.fillOffer(1), TAKER)
check("fee snapshot: old 0.25% applies after fee change", usdc.functions.balanceOf(TAKER).call() == tu + 1 * U - 2500)
check("fee above 3% rejected", reverts(otc.functions.setFeeBps(301), OWNER, "fee too high"))
tx(otc.functions.setMaxOfferAmount(usdc.address, 50 * U), OWNER)
check("per-asset cap enforced", reverts(otc.functions.createOfferGivingUsdc(tok.address, 1, 51 * U, "0x" + "00" * 20, 0), MAKER, "exceeds per-offer cap"))
tx(otc.functions.setPaused(True), OWNER)
check("pause blocks new offers", reverts(otc.functions.createOfferGivingUsdc(tok.address, 1, 1 * U, "0x" + "00" * 20, 0), MAKER, "offers paused"))
check("native value rejected (nothing payable)", reverts(otc.functions.fillOffer(1), TAKER, value=1))
try:
    w3.eth.send_transaction({"from": TAKER, "to": otc.address, "value": 1}); ok = False
except Exception:
    ok = True
check("plain native send to escrow rejected", ok)
check("non-owner cannot change fee", reverts(otc.functions.setFeeBps(10), OTHER, "not owner"))

# 10. two-step ownership
tx(otc.functions.transferOwnership(OTHER), OWNER)
check("ownership pending until accepted", otc.functions.owner().call() == OWNER)
check("only pending owner can accept", reverts(otc.functions.acceptOwnership(), TAKER, "not pending owner"))
tx(otc.functions.acceptOwnership(), OTHER)
check("ownership transferred", otc.functions.owner().call() == OTHER)

print(f"{len(passed)} checks passed")
for p in passed: print("  ok -", p)
