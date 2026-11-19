// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChordOTCv2} from "../../contracts/ChordOTCv2.sol";
import {MockToken} from "../Mocks.sol";

/// A token that tries to call back into Chord while being moved.
contract ReenterToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    ChordOTCv2 public chord;
    uint256 public targetId;
    bool public armed;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function arm(ChordOTCv2 c, uint256 id) external { chord = c; targetId = id; armed = true; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        if (armed) { armed = false; chord.fillOffer(targetId); }
        return true;
    }
}

/// USDT-style token: transferFrom returns nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external { allowance[msg.sender][s] = a; }
    function transferFrom(address f, address t, uint256 a) external {
        require(allowance[f][msg.sender] >= a && balanceOf[f] >= a);
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
    }
}

contract ChordOTCv2Base is Test {
    ChordOTCv2 chord;
    MockToken usdc;
    MockToken tok;
    address owner = address(this);
    address treasury = makeAddr("treasury");
    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    address other = makeAddr("other");

    uint256 constant U = 1_000e6; // 1,000 USDC
    uint256 constant T = 500e18; // 500 tokens

    function setUp() public virtual {
        usdc = new MockToken("USD Coin", "USDC", 6);
        tok = new MockToken("Token", "TOK", 18);
        chord = new ChordOTCv2(address(usdc), treasury);
        for (uint256 i; i < 3; i++) {
            address a = [maker, taker, other][i];
            usdc.mint(a, 1_000_000e6);
            tok.mint(a, 1_000_000e18);
            vm.startPrank(a);
            usdc.approve(address(chord), type(uint256).max);
            tok.approve(address(chord), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _giveUsdc(address taker_, uint64 exp) internal returns (uint256) {
        vm.prank(maker);
        return chord.createOfferGivingUsdc(address(tok), T, U, taker_, exp);
    }

    function _giveToken(address taker_, uint64 exp) internal returns (uint256) {
        vm.prank(maker);
        return chord.createOfferGivingToken(address(tok), T, U, taker_, exp);
    }

    function _assertHoldsNothing() internal view {
        assertEq(usdc.balanceOf(address(chord)), 0, "holds USDC");
        assertEq(tok.balanceOf(address(chord)), 0, "holds token");
        assertEq(address(chord).balance, 0, "holds native");
    }
}

contract ChordOTCv2Test is ChordOTCv2Base {
    // --- Both directions -------------------------------------------------

    function test_makerGivesUsdc_fill() public {
        uint256 mu = usdc.balanceOf(maker); uint256 mt = tok.balanceOf(maker);
        uint256 tu = usdc.balanceOf(taker); uint256 tt = tok.balanceOf(taker);
        uint256 id = _giveUsdc(address(0), 0);
        // Creating moves nothing.
        assertEq(usdc.balanceOf(maker), mu);
        _assertHoldsNothing();
        assertTrue(chord.offerReady(id));

        vm.prank(taker);
        chord.fillOffer(id);

        uint256 fee = U * 25 / 10_000; // 2.5 USDC
        assertEq(usdc.balanceOf(maker), mu - U);
        assertEq(tok.balanceOf(maker), mt + T);
        assertEq(usdc.balanceOf(taker), tu + U - fee);
        assertEq(tok.balanceOf(taker), tt - T);
        assertEq(usdc.balanceOf(treasury), fee);
        _assertHoldsNothing();
        assertEq(uint256(chord.getOffer(id).status), uint256(ChordOTCv2.Status.Filled));
        assertFalse(chord.offerReady(id));
    }

    function test_makerGivesToken_fill() public {
        uint256 mu = usdc.balanceOf(maker); uint256 mt = tok.balanceOf(maker);
        uint256 tu = usdc.balanceOf(taker); uint256 tt = tok.balanceOf(taker);
        uint256 id = _giveToken(address(0), 0);
        assertEq(tok.balanceOf(maker), mt);
        vm.prank(taker);
        chord.fillOffer(id);
        uint256 fee = U * 25 / 10_000;
        assertEq(tok.balanceOf(maker), mt - T);
        assertEq(usdc.balanceOf(maker), mu + U - fee);
        assertEq(tok.balanceOf(taker), tt + T);
        assertEq(usdc.balanceOf(taker), tu - U);
        assertEq(usdc.balanceOf(treasury), fee);
        _assertHoldsNothing();
    }

    function test_noReturnToken_works() public {
        NoReturnToken nr = new NoReturnToken();
        nr.mint(maker, T);
        vm.prank(maker); nr.approve(address(chord), T);
        vm.prank(maker);
        uint256 id = chord.createOfferGivingToken(address(nr), T, U, address(0), 0);
        vm.prank(taker); chord.fillOffer(id);
        assertEq(nr.balanceOf(taker), T);
    }

    // --- Maker's funds moved after posting -------------------------------

    function test_makerMovesUsdcAway_fillFails_takerKeepsAll() public {
        uint256 id = _giveUsdc(address(0), 0);
        uint256 bal = usdc.balanceOf(maker);
        vm.prank(maker); usdc.transfer(other, bal);
        assertFalse(chord.offerReady(id));
        assertTrue(chord.isFillable(id));
        uint256 tt = tok.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert("token transferFrom failed");
        chord.fillOffer(id);
        assertEq(tok.balanceOf(taker), tt);
        assertEq(uint256(chord.getOffer(id).status), uint256(ChordOTCv2.Status.Open));
    }

    function test_makerRevokesApproval_fillFails() public {
        uint256 id = _giveToken(address(0), 0);
        vm.prank(maker); tok.approve(address(chord), 0);
        assertFalse(chord.offerReady(id));
        uint256 tu = usdc.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert("token transferFrom failed");
        chord.fillOffer(id);
        assertEq(usdc.balanceOf(taker), tu);
    }

    // --- Create checks ---------------------------------------------------

    function test_create_needsBalanceAndApproval() public {
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert("maker balance too low");
        chord.createOfferGivingUsdc(address(tok), T, U, address(0), 0);
        usdc.mint(poor, U);
        vm.prank(poor);
        vm.expectRevert("approve first");
        chord.createOfferGivingUsdc(address(tok), T, U, address(0), 0);
    }

    function test_create_inputChecks() public {
        vm.startPrank(maker);
        vm.expectRevert("bad token");
        chord.createOfferGivingUsdc(address(usdc), T, U, address(0), 0);
        vm.expectRevert("bad token");
        chord.createOfferGivingUsdc(address(0), T, U, address(0), 0);
        vm.expectRevert("token has no code");
        chord.createOfferGivingUsdc(makeAddr("eoa"), T, U, address(0), 0);
        vm.expectRevert("amountToken = 0");
        chord.createOfferGivingUsdc(address(tok), 0, U, address(0), 0);
        vm.expectRevert("amountUsdc = 0");
        chord.createOfferGivingUsdc(address(tok), T, 0, address(0), 0);
        vm.expectRevert("taker is maker");
        chord.createOfferGivingUsdc(address(tok), T, U, maker, 0);
        vm.expectRevert("expiry in the past");
        chord.createOfferGivingUsdc(address(tok), T, U, address(0), uint64(block.timestamp));
        vm.stopPrank();
    }

    // --- Fill rules ------------------------------------------------------

    function test_expiry() public {
        uint64 exp = uint64(block.timestamp + 1 hours);
        uint256 id = _giveUsdc(address(0), exp);
        vm.warp(exp); // still fine at exactly expiresAt
        assertTrue(chord.offerReady(id));
        vm.warp(exp + 1);
        assertFalse(chord.isFillable(id));
        assertFalse(chord.offerReady(id));
        vm.prank(taker);
        vm.expectRevert("offer expired");
        chord.fillOffer(id);
        // The maker can still cancel an expired offer.
        vm.prank(maker); chord.cancelOffer(id);
    }

    function test_privateTaker() public {
        uint256 id = _giveUsdc(taker, 0);
        vm.prank(other);
        vm.expectRevert("not your offer to fill");
        chord.fillOffer(id);
        vm.prank(taker); chord.fillOffer(id);
    }

    function test_fillOnceOnly_andNotOwn() public {
        uint256 id = _giveUsdc(address(0), 0);
        vm.prank(maker);
        vm.expectRevert("cannot fill own offer");
        chord.fillOffer(id);
        vm.prank(taker); chord.fillOffer(id);
        vm.prank(other);
        vm.expectRevert("not open");
        chord.fillOffer(id);
        vm.prank(other);
        vm.expectRevert("not open");
        chord.fillOffer(999);
    }

    function test_cancel() public {
        uint256 id = _giveToken(address(0), 0);
        vm.prank(other);
        vm.expectRevert("not your offer");
        chord.cancelOffer(id);
        uint256 mt = tok.balanceOf(maker);
        vm.prank(maker); chord.cancelOffer(id);
        assertEq(tok.balanceOf(maker), mt); // nothing to refund, nothing moved
        vm.prank(taker);
        vm.expectRevert("not open");
        chord.fillOffer(id);
        vm.prank(maker);
        vm.expectRevert("not open");
        chord.cancelOffer(id);
    }

    // --- Blocklist (Arc USDC) --------------------------------------------

    function test_blockedTaker_fillReverts_nothingLost() public {
        uint256 id = _giveUsdc(address(0), 0);
        usdc.setBlocked(taker, true);
        uint256 mu = usdc.balanceOf(maker); uint256 tt = tok.balanceOf(taker);
        vm.prank(taker);
        vm.expectRevert("token transferFrom failed");
        chord.fillOffer(id);
        assertEq(usdc.balanceOf(maker), mu);
        assertEq(tok.balanceOf(taker), tt);
        usdc.setBlocked(taker, false);
        vm.prank(taker); chord.fillOffer(id);
    }

    function test_blockedFeeRecipient_ownerRedirects() public {
        uint256 id = _giveToken(address(0), 0);
        usdc.setBlocked(treasury, true);
        vm.prank(taker);
        vm.expectRevert("token transferFrom failed");
        chord.fillOffer(id);
        address t2 = makeAddr("treasury2");
        chord.setFeeRecipient(t2);
        vm.prank(taker); chord.fillOffer(id);
        assertEq(usdc.balanceOf(t2), U * 25 / 10_000);
    }

    // --- Fee-on-transfer --------------------------------------------------

    function test_feeOnTransferToken_refused_bothDirections() public {
        tok.setFeeBps(100);
        uint256 a = _giveUsdc(address(0), 0);
        vm.prank(taker);
        vm.expectRevert("token took a transfer fee or rebased - unsupported");
        chord.fillOffer(a);
        uint256 b = _giveToken(address(0), 0);
        vm.prank(taker);
        vm.expectRevert("token took a transfer fee or rebased - unsupported");
        chord.fillOffer(b);
    }

    // --- Fee, caps, pause ------------------------------------------------

    function test_feeFixedAtCreation_andZeroFee() public {
        uint256 id = _giveToken(address(0), 0); // 0.25%
        chord.setFeeBps(300);
        uint256 id0;
        chord.setFeeBps(0);
        id0 = _giveToken(address(0), 0);
        vm.prank(taker); chord.fillOffer(id);
        assertEq(usdc.balanceOf(treasury), U * 25 / 10_000);
        vm.prank(taker); chord.fillOffer(id0);
        assertEq(usdc.balanceOf(treasury), U * 25 / 10_000); // no fee on the zero-fee offer
    }

    function test_caps() public {
        chord.setMaxOfferAmount(address(usdc), U - 1);
        vm.prank(maker);
        vm.expectRevert("exceeds per-offer cap");
        chord.createOfferGivingUsdc(address(tok), T, U, address(0), 0);
        vm.prank(maker);
        vm.expectRevert("exceeds per-offer cap");
        chord.createOfferGivingToken(address(tok), T, U, address(0), 0);
        chord.setMaxOfferAmount(address(usdc), 0);
        chord.setMaxOfferAmount(address(tok), T - 1);
        vm.prank(maker);
        vm.expectRevert("exceeds per-offer cap");
        chord.createOfferGivingToken(address(tok), T, U, address(0), 0);
    }

    function test_pause_blocksCreateAndFill_notCancel() public {
        uint256 id = _giveUsdc(address(0), 0);
        uint256 id2 = _giveUsdc(address(0), 0);
        chord.setPaused(true);
        assertFalse(chord.offerReady(id));
        vm.prank(maker);
        vm.expectRevert("paused");
        chord.createOfferGivingUsdc(address(tok), T, U, address(0), 0);
        vm.prank(taker);
        vm.expectRevert("paused");
        chord.fillOffer(id);
        vm.prank(maker); chord.cancelOffer(id2);
        chord.setPaused(false);
        vm.prank(taker); chord.fillOffer(id);
    }

    // --- Admin -----------------------------------------------------------

    function test_admin_limits() public {
        vm.expectRevert("fee too high");
        chord.setFeeBps(301);
        vm.expectRevert("bad recipient");
        chord.setFeeRecipient(address(0));
        vm.startPrank(other);
        vm.expectRevert("not owner");
        chord.setFeeBps(10);
        vm.expectRevert("not owner");
        chord.setPaused(true);
        vm.expectRevert("not owner");
        chord.setFeeRecipient(other);
        vm.expectRevert("not owner");
        chord.setMaxOfferAmount(address(tok), 1);
        vm.expectRevert("not owner");
        chord.transferOwnership(other);
        vm.stopPrank();
    }

    function test_twoStepOwnership() public {
        chord.transferOwnership(other);
        assertEq(chord.owner(), owner);
        vm.prank(taker);
        vm.expectRevert("not pending owner");
        chord.acceptOwnership();
        vm.prank(other); chord.acceptOwnership();
        assertEq(chord.owner(), other);
        assertEq(chord.pendingOwner(), address(0));
    }

    function test_constructorChecks() public {
        vm.expectRevert("bad usdc");
        new ChordOTCv2(makeAddr("noCode"), treasury);
        vm.expectRevert("bad fee recipient");
        new ChordOTCv2(address(usdc), address(0));
    }

    function test_refusesNativeValue() public {
        vm.deal(taker, 1 ether);
        vm.prank(taker);
        (bool ok, ) = address(chord).call{value: 1}("");
        assertFalse(ok);
    }

    // --- Reentrancy ------------------------------------------------------

    function test_reentrancy_blocked() public {
        ReenterToken rt = new ReenterToken();
        rt.mint(maker, T);
        vm.prank(maker); rt.approve(address(chord), type(uint256).max);
        vm.prank(maker);
        uint256 id = chord.createOfferGivingToken(address(rt), T, U, address(0), 0);
        rt.mint(maker, T);
        vm.prank(maker);
        uint256 id2 = chord.createOfferGivingToken(address(rt), T, U, address(0), 0);
        rt.arm(chord, id2);
        vm.prank(taker);
        vm.expectRevert("token transferFrom failed");
        chord.fillOffer(id);
    }

    // --- Fuzz ------------------------------------------------------------

    function testFuzz_valueConserved(uint256 amtU, uint256 amtT, uint16 fee, bool makerGivesUsdc) public {
        amtU = bound(amtU, 1, 1_000_000e6);
        amtT = bound(amtT, 1, 1_000_000e18);
        fee = uint16(bound(fee, 0, 300));
        chord.setFeeBps(fee);
        uint256 supU = usdc.balanceOf(maker) + usdc.balanceOf(taker);
        uint256 supT = tok.balanceOf(maker) + tok.balanceOf(taker);
        vm.prank(maker);
        uint256 id = makerGivesUsdc
            ? chord.createOfferGivingUsdc(address(tok), amtT, amtU, address(0), 0)
            : chord.createOfferGivingToken(address(tok), amtT, amtU, address(0), 0);
        vm.prank(taker); chord.fillOffer(id);
        uint256 f = amtU * fee / 10_000;
        assertEq(usdc.balanceOf(treasury), f);
        assertEq(usdc.balanceOf(maker) + usdc.balanceOf(taker) + f, supU);
        assertEq(tok.balanceOf(maker) + tok.balanceOf(taker), supT);
        _assertHoldsNothing();
    }
}

// --- Invariant: the contract never holds anything ------------------------

contract ChordV2Handler is Test {
    ChordOTCv2 chord;
    MockToken usdc;
    MockToken tok;
    address[3] actors;
    uint256[] public ids;

    constructor(ChordOTCv2 c, MockToken u, MockToken t, address[3] memory a) {
        chord = c; usdc = u; tok = t; actors = a;
    }

    function create(uint256 who, uint256 amtU, uint256 amtT, bool giveUsdc) external {
        address m = actors[who % 3];
        amtU = bound(amtU, 1, 10_000e6);
        amtT = bound(amtT, 1, 10_000e18);
        vm.prank(m);
        if (giveUsdc) {
            try chord.createOfferGivingUsdc(address(tok), amtT, amtU, address(0), 0) returns (uint256 id) {
                ids.push(id);
            } catch {}
        } else {
            try chord.createOfferGivingToken(address(tok), amtT, amtU, address(0), 0) returns (uint256 id) {
                ids.push(id);
            } catch {}
        }
    }

    function fill(uint256 who, uint256 idx) external {
        if (ids.length == 0) return;
        vm.prank(actors[who % 3]);
        try chord.fillOffer(ids[idx % ids.length]) {} catch {}
    }

    function cancel(uint256 idx) external {
        if (ids.length == 0) return;
        uint256 id = ids[idx % ids.length];
        vm.prank(chord.getOffer(id).maker);
        try chord.cancelOffer(id) {} catch {}
    }

    function moveAway(uint256 who, uint256 to, uint256 amt, bool isUsdc) external {
        address f = actors[who % 3];
        address t = actors[to % 3];
        MockToken k = isUsdc ? usdc : tok;
        amt = bound(amt, 0, k.balanceOf(f));
        vm.prank(f);
        k.transfer(t, amt);
    }
}

contract ChordOTCv2Invariant is ChordOTCv2Base {
    ChordV2Handler h;

    function setUp() public override {
        super.setUp();
        h = new ChordV2Handler(chord, usdc, tok, [maker, taker, other]);
        targetContract(address(h));
    }

    function invariant_holdsNothing() public view {
        _assertHoldsNothing();
    }

    function invariant_supplyConserved() public view {
        assertEq(usdc.balanceOf(maker) + usdc.balanceOf(taker) + usdc.balanceOf(other) + usdc.balanceOf(treasury), 3_000_000e6);
        assertEq(tok.balanceOf(maker) + tok.balanceOf(taker) + tok.balanceOf(other), 3_000_000e18);
    }
}
