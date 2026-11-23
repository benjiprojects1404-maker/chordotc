// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ChordOTCv2} from "../../contracts/ChordOTCv2.sol";
import {ChordOTCv2Base} from "./ChordOTCv2.t.sol";

/// Token that, when armed, calls back into Chord with any calldata during transferFrom and records the
/// revert reason of that call. It then completes its own transfer, so the outer call carries on and the test
/// can check that the re-entry itself was refused by the reentrancy guard.
contract ProbeToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public target;
    bytes public payload;
    bool public armed;
    bool public innerOk;
    bytes public innerRevert;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function arm(address t, bytes calldata data) external { target = t; payload = data; armed = true; }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        if (armed) {
            armed = false;
            (innerOk, innerRevert) = target.call(payload);
        }
        return true;
    }
}

contract ChordOTCv2_1Test is ChordOTCv2Base {
    address alice = makeAddr("alice");
    address bot = makeAddr("bot");

    function _reason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 68) return "";
        assembly { ret := add(ret, 4) }
        return abi.decode(ret, (string));
    }

    function setUp() public override {
        super.setUp();
        usdc.mint(bot, 1_000_000e6);
        vm.prank(bot);
        usdc.approve(address(chord), type(uint256).max);
    }

    // ---- 5.1.1: a stale offer can't be revived by a newer offer's approval -------------------

    /// Olympix PoC (requireBacked_unaccounted_shared_allowance_stale_offer_revival), now expected to hold.
    function test_5_1_1_staleOfferNotRevivedByNewApproval() public {
        tok.mint(alice, 100e18);
        vm.startPrank(alice);
        tok.approve(address(chord), 100e18);
        uint256 idA = chord.createOfferGivingToken(address(tok), 100e18, 100e6, address(0), 0, 300);
        tok.transfer(other, 100e18); // A goes stale
        vm.stopPrank();
        assertFalse(chord.offerReady(idA));

        // Alice re-acquires 100 and approves exactly 100 for a new offer B at 200 USDC: refused, because A
        // still has 100 committed and the approval and balance only cover one of them.
        tok.mint(alice, 100e18);
        vm.startPrank(alice);
        tok.approve(address(chord), 100e18);
        vm.expectRevert("maker balance too low for all your open offers");
        chord.createOfferGivingToken(address(tok), 100e18, 200e6, address(0), 0, 300);

        // She cancels A, then B goes through; A can no longer be filled.
        chord.cancelOffer(idA);
        uint256 idB = chord.createOfferGivingToken(address(tok), 100e18, 200e6, address(0), 0, 300);
        vm.stopPrank();

        vm.prank(bot);
        vm.expectRevert("not open");
        chord.fillOffer(idA);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(bot);
        chord.fillOffer(idB);
        assertEq(usdc.balanceOf(alice) - before, 200e6 - (200e6 * 25) / 10_000, "sold at B's price");
    }

    /// Approval alone covering only the new offer is also refused (balance for both, approval for one).
    function test_5_1_1_approvalMustCoverAllOpenOffers() public {
        tok.mint(alice, 200e18);
        vm.startPrank(alice);
        tok.approve(address(chord), 100e18);
        chord.createOfferGivingToken(address(tok), 100e18, 100e6, address(0), 0, 300);
        vm.expectRevert("approve enough for all your open offers");
        chord.createOfferGivingToken(address(tok), 100e18, 200e6, address(0), 0, 300);
        tok.approve(address(chord), 200e18); // deliberately backing both is fine
        chord.createOfferGivingToken(address(tok), 100e18, 200e6, address(0), 0, 300);
        vm.stopPrank();
        assertEq(chord.committed(alice, address(tok)), 200e18);
    }

    function test_committed_releasedOnFillAndCancel_perAsset() public {
        uint256 a = _giveToken(address(0), 0); // maker gives T tok
        uint256 b = _giveToken(address(0), 0);
        uint256 c = _giveUsdc(address(0), 0); // maker gives U usdc
        assertEq(chord.committed(maker, address(tok)), 2 * T);
        assertEq(chord.committed(maker, address(usdc)), U);

        vm.prank(taker);
        chord.fillOffer(a);
        assertEq(chord.committed(maker, address(tok)), T, "fill releases");

        vm.prank(maker);
        chord.cancelOffer(b);
        assertEq(chord.committed(maker, address(tok)), 0, "cancel releases");

        vm.prank(taker);
        chord.fillOffer(c);
        assertEq(chord.committed(maker, address(usdc)), 0, "usdc side released");
    }

    function test_committed_expiredOfferStaysUntilCancelled() public {
        tok.mint(alice, 100e18);
        vm.startPrank(alice);
        tok.approve(address(chord), 100e18);
        uint256 id = chord.createOfferGivingToken(address(tok), 100e18, 100e6, address(0), uint64(block.timestamp + 1 hours), 300);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert("maker balance too low for all your open offers");
        chord.createOfferGivingToken(address(tok), 100e18, 120e6, address(0), 0, 300);
        chord.cancelOffer(id); // expired offers can be cancelled to release them
        chord.createOfferGivingToken(address(tok), 100e18, 120e6, address(0), 0, 300);
        vm.stopPrank();
    }

    function test_committed_neverUnderflows_fuzz(uint8 n, uint256 seed) public {
        n = uint8(bound(n, 1, 12));
        uint256[] memory ids = new uint256[](n);
        uint256 sum;
        for (uint256 i; i < n; i++) {
            uint256 amt = bound(uint256(keccak256(abi.encode(seed, i))), 1, 1_000e18);
            vm.prank(maker);
            ids[i] = chord.createOfferGivingToken(address(tok), amt, 1e6, address(0), 0, 300);
            sum += amt;
        }
        assertEq(chord.committed(maker, address(tok)), sum);
        for (uint256 i; i < n; i++) {
            if (uint256(keccak256(abi.encode(seed, i, "x"))) % 2 == 0) { vm.prank(maker); chord.cancelOffer(ids[i]); }
            else { vm.prank(taker); chord.fillOffer(ids[i]); }
        }
        assertEq(chord.committed(maker, address(tok)), 0);
    }

    // ---- 5.2.1: maker-supplied maximum fee ------------------------------------------------------

    function test_5_2_1_feeAboveMakerMaxReverts() public {
        chord.setFeeBps(300); // e.g. a fee change landing before the maker's pending create
        vm.startPrank(maker);
        vm.expectRevert("fee above your max");
        chord.createOfferGivingToken(address(tok), T, U, address(0), 0, 25);
        vm.expectRevert("fee above your max");
        chord.createOfferGivingUsdc(address(tok), T, U, address(0), 0, 25);
        vm.stopPrank();

        chord.setFeeBps(25);
        vm.prank(maker);
        uint256 id = chord.createOfferGivingToken(address(tok), T, U, address(0), 0, 25); // equal is fine
        assertEq(chord.getOffer(id).feeBpsAtCreation, 25);
    }

    function test_5_2_1_offerCreatedEmitsFee() public {
        chord.setFeeBps(40);
        vm.expectEmit(true, true, true, true, address(chord));
        emit ChordOTCv2.OfferCreated(1, maker, address(0), address(tok), U, T, false, 0, 40);
        vm.prank(maker);
        chord.createOfferGivingToken(address(tok), T, U, address(0), 0, 300);
    }

    // ---- Reentrancy: every entry point is guarded -----------------------------------------------
    // A ProbeToken re-enters Chord from inside a fill and records why that inner call failed.

    function _probeFill(bytes memory reentry) internal returns (ProbeToken p) {
        p = new ProbeToken();
        p.mint(maker, 10 * T);
        vm.prank(maker);
        p.approve(address(chord), type(uint256).max);
        vm.prank(maker);
        uint256 id = chord.createOfferGivingToken(address(p), T, U, address(0), 0, 300);
        vm.prank(maker);
        chord.createOfferGivingToken(address(p), T, U, address(0), 0, 300); // id + 1, a target to re-enter on
        p.arm(address(chord), reentry);
        vm.prank(taker);
        chord.fillOffer(id);
    }

    function test_reentrancy_fillIntoFill() public {
        ProbeToken p = _probeFill(abi.encodeCall(ChordOTCv2.fillOffer, (2)));
        assertFalse(p.innerOk());
        assertEq(_reason(p.innerRevert()), "reentrancy");
        assertEq(uint8(chord.getOffer(2).status), uint8(ChordOTCv2.Status.Open), "second offer untouched");
    }

    function test_reentrancy_fillIntoCreateGivingToken() public {
        ProbeToken p = _probeFill(abi.encodeCall(ChordOTCv2.createOfferGivingToken, (address(tok), T, U, address(0), 0, 300)));
        assertFalse(p.innerOk());
        assertEq(_reason(p.innerRevert()), "reentrancy");
        assertEq(chord.totalOffers(), 2, "no offer created during the fill");
    }

    function test_reentrancy_fillIntoCreateGivingUsdc() public {
        ProbeToken p = _probeFill(abi.encodeCall(ChordOTCv2.createOfferGivingUsdc, (address(tok), T, U, address(0), 0, 300)));
        assertFalse(p.innerOk());
        assertEq(_reason(p.innerRevert()), "reentrancy");
        assertEq(chord.totalOffers(), 2, "no offer created during the fill");
    }

    // ---- Views ----------------------------------------------------------------------------------

    // ---- CHORD-02 (Proovant): a fill can't spend what backs the taker's own open offers ------------

    function _aliceOffersUsdc(uint256 amt) internal returns (uint256 id) {
        usdc.mint(alice, amt);
        vm.startPrank(alice);
        usdc.approve(address(chord), amt);
        id = chord.createOfferGivingUsdc(address(tok), 1e18, amt, address(0), 0, 300);
        vm.stopPrank();
    }
    function _botOffersToken(uint256 usdcWanted) internal returns (uint256 id) {
        tok.mint(bot, 1e18);
        vm.startPrank(bot);
        tok.approve(address(chord), 1e18);
        id = chord.createOfferGivingToken(address(tok), 1e18, usdcWanted, address(0), 0, 300);
        vm.stopPrank();
    }

    /// Proovant's scenario: Alice's 1,000 USDC offer is backed by a 1,000 approval; filling Bob's 600 USDC
    /// offer with that same approval would leave hers unbacked. Now refused until she approves on top.
    function test_CHORD02_fillCantSpendTakersCommittedApproval() public {
        uint256 mine = _aliceOffersUsdc(1_000e6);
        uint256 theirs = _botOffersToken(600e6);
        usdc.mint(alice, 600e6);

        vm.prank(alice);
        vm.expectRevert("approve this fill on top of your own open offers");
        chord.fillOffer(theirs);
        assertTrue(chord.offerReady(mine));

        vm.startPrank(alice);
        usdc.approve(address(chord), 1_600e6);
        chord.fillOffer(theirs);
        vm.stopPrank();
        assertTrue(chord.offerReady(mine), "her own offer stays backed");
        assertEq(usdc.allowance(alice, address(chord)), 1_000e6);
    }

    function test_CHORD02_fillCantSpendTakersCommittedBalance() public {
        uint256 mine = _aliceOffersUsdc(1_000e6); // she holds exactly 1,000
        uint256 theirs = _botOffersToken(600e6);
        vm.startPrank(alice);
        usdc.approve(address(chord), 1_600e6);
        vm.expectRevert("fill would leave your own open offers short of balance");
        chord.fillOffer(theirs);
        vm.stopPrank();
        assertTrue(chord.offerReady(mine));
    }

    function test_CHORD02_noOwnOffers_exactApprovalStillWorks() public {
        uint256 theirs = _botOffersToken(600e6);
        usdc.mint(alice, 600e6);
        vm.startPrank(alice);
        usdc.approve(address(chord), 600e6);
        chord.fillOffer(theirs);
        vm.stopPrank();
        assertEq(uint8(chord.getOffer(theirs).status), uint8(ChordOTCv2.Status.Filled));
    }

    function test_CHORD02_commitmentOnOtherAssetDoesntBlock() public {
        // Alice's open offer gives the token; she pays USDC for this fill, so it's unaffected.
        tok.mint(alice, 5e18);
        vm.startPrank(alice);
        tok.approve(address(chord), 5e18);
        chord.createOfferGivingToken(address(tok), 5e18, 5_000e6, address(0), 0, 300);
        vm.stopPrank();
        uint256 theirs = _botOffersToken(600e6);
        usdc.mint(alice, 600e6);
        vm.startPrank(alice);
        usdc.approve(address(chord), 600e6);
        chord.fillOffer(theirs);
        vm.stopPrank();
    }

    function test_CHORD02_fuzz_takerOffersAlwaysBackedAfterFill(uint96 own, uint96 fill, uint96 extra) public {
        own = uint96(bound(own, 1, 1_000e6));
        fill = uint96(bound(fill, 1, 1_000e6));
        uint256 mine = _aliceOffersUsdc(own);
        uint256 theirs = _botOffersToken(fill);
        usdc.mint(alice, fill);
        vm.startPrank(alice);
        usdc.approve(address(chord), uint256(own) + bound(extra, 0, uint256(fill) * 2));
        try chord.fillOffer(theirs) {} catch {}
        vm.stopPrank();
        assertTrue(chord.offerReady(mine), "taker's own offer must stay backed whether or not the fill went through");
    }

    function test_views_totalOffersAndReadiness() public {
        assertEq(chord.totalOffers(), 0);
        uint256 id = _giveToken(address(0), uint64(block.timestamp + 1 hours));
        _giveUsdc(address(0), 0);
        assertEq(chord.totalOffers(), 2);
        assertTrue(chord.isFillable(id));
        assertTrue(chord.offerReady(id));
        chord.setPaused(true);
        assertFalse(chord.offerReady(id), "paused");
        assertTrue(chord.isFillable(id), "isFillable ignores pause");
        chord.setPaused(false);
        vm.warp(block.timestamp + 2 hours);
        assertFalse(chord.isFillable(id), "expired");
        assertFalse(chord.offerReady(id), "expired");
        assertFalse(chord.isFillable(99), "unknown id");
        assertFalse(chord.offerReady(99), "unknown id");
    }
}
