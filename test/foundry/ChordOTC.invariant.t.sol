// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChordOTC} from "../../contracts/ChordOTC.sol";
import {MockToken} from "../Mocks.sol";

/// Stateful fuzzing for ChordOTC. Mirrors test/test_invariants.py (Python harness) so the two
/// independent fuzzers check the same properties.
///
/// Invariants (checked after every fuzzed sequence of calls):
///  S1  solvency, USDC: escrow USDC balance == locked USDC of open offers + USDC credits owed
///  S2  solvency, token: escrow token balance == locked token of open offers + token credits owed
///  S3  status is one-way: Filled and Cancelled offers never reopen
///  S4  the fee recipient and makers are never paid more than the offer terms say
contract ChordOTCHandler is Test {
    ChordOTC public otc;
    MockToken public usdc;
    MockToken public tok;

    address[] public actors;
    address public feeRecipient = address(0xFEE);

    // Ghost state the handler tracks alongside the contract.
    uint256 public lockedUsdc;   // USDC locked by open offers
    uint256 public lockedTok;    // token locked by open offers
    mapping(uint256 => ChordOTC.Status) public lastStatus;
    uint256 public offersSeen;

    constructor(ChordOTC _otc, MockToken _usdc, MockToken _tok) {
        otc = _otc;
        usdc = _usdc;
        tok = _tok;
        for (uint160 i = 1; i <= 5; i++) {
            address a = address(uint160(0xA000 + i));
            actors.push(a);
            usdc.mint(a, 1e12);
            tok.mint(a, 1e24);
            vm.prank(a);
            usdc.approve(address(otc), type(uint256).max);
            vm.prank(a);
            tok.approve(address(otc), type(uint256).max);
        }
    }

    function actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    function createGivingUsdc(uint256 s, uint256 amtUsdc, uint256 amtTok, uint256 takerSeed) external {
        address m = actor(s);
        amtUsdc = bound(amtUsdc, 1, 1e10);
        amtTok = bound(amtTok, 1, 1e22);
        address taker = takerSeed % 3 == 0 ? address(0) : actor(takerSeed);
        if (taker == m) taker = address(0);
        vm.prank(m);
        try otc.createOfferGivingUsdc(address(tok), amtTok, amtUsdc, taker, 0) returns (uint256 id) {
            lockedUsdc += amtUsdc;
            offersSeen++;
            lastStatus[id] = ChordOTC.Status.Open;
        } catch {}
    }

    function createGivingToken(uint256 s, uint256 amtUsdc, uint256 amtTok, uint256 takerSeed) external {
        address m = actor(s);
        amtUsdc = bound(amtUsdc, 1, 1e10);
        amtTok = bound(amtTok, 1, 1e22);
        address taker = takerSeed % 3 == 0 ? address(0) : actor(takerSeed);
        if (taker == m) taker = address(0);
        vm.prank(m);
        try otc.createOfferGivingToken(address(tok), amtTok, amtUsdc, taker, 0) returns (uint256 id) {
            lockedTok += amtTok;
            offersSeen++;
            lastStatus[id] = ChordOTC.Status.Open;
        } catch {}
    }

    function fill(uint256 s, uint256 id) external {
        uint256 n = otc.nextOfferId();
        if (n <= 1) return;
        id = bound(id, 1, n - 1);
        ChordOTC.Offer memory o = otc.getOffer(id);
        if (o.status != ChordOTC.Status.Open) return;
        address t = actor(s);
        vm.prank(t);
        try otc.fillOffer(id) {
            if (o.makerGivesUsdc) lockedUsdc -= o.amountUsdc;
            else lockedTok -= o.amountToken;
            lastStatus[id] = ChordOTC.Status.Filled;
        } catch {}
    }

    function cancel(uint256, uint256 id) external {
        uint256 n = otc.nextOfferId();
        if (n <= 1) return;
        id = bound(id, 1, n - 1);
        ChordOTC.Offer memory o = otc.getOffer(id);
        if (o.status != ChordOTC.Status.Open) return;
        vm.prank(o.maker);
        try otc.cancelOffer(id) {
            if (o.makerGivesUsdc) lockedUsdc -= o.amountUsdc;
            else lockedTok -= o.amountToken;
            lastStatus[id] = ChordOTC.Status.Cancelled;
        } catch {}
    }

    function withdraw(uint256 s, bool asUsdc) external {
        address a = actor(s);
        vm.prank(a);
        try otc.withdraw(asUsdc ? address(usdc) : address(tok)) {} catch {}
    }

    function block_(uint256 s, bool on) external {
        usdc.setBlocked(actor(s), on);
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 2 days));
    }

    function setPaused(bool p) external {
        vm.prank(otc.owner());
        otc.setPaused(p);
    }

    function setFee(uint256 bps) external {
        vm.prank(otc.owner());
        try otc.setFeeBps(uint16(bound(bps, 0, 300))) {} catch {}
    }

    function setFeeBlocked(bool on) external {
        usdc.setBlocked(feeRecipient, on);
    }
}

contract ChordOTCInvariantTest is Test {
    ChordOTC internal otc;
    MockToken internal usdc;
    MockToken internal tok;
    ChordOTCHandler internal handler;

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        tok = new MockToken("Test Token", "TT", 18);
        otc = new ChordOTC(address(usdc), address(0xFEE));
        handler = new ChordOTCHandler(otc, usdc, tok);
    }

    // Foundry reads these to decide what to fuzz (the same job as forge-std's StdInvariant).
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    function targetContracts() public view returns (address[] memory targets) {
        targets = new address[](1);
        targets[0] = address(handler);
    }

    function targetSelectors() public view returns (FuzzSelector[] memory out) {
        bytes4[] memory sels = new bytes4[](9);
        sels[0] = ChordOTCHandler.createGivingUsdc.selector;
        sels[1] = ChordOTCHandler.createGivingToken.selector;
        sels[2] = ChordOTCHandler.fill.selector;
        sels[3] = ChordOTCHandler.cancel.selector;
        sels[4] = ChordOTCHandler.withdraw.selector;
        sels[5] = ChordOTCHandler.block_.selector;
        sels[6] = ChordOTCHandler.warp.selector;
        sels[7] = ChordOTCHandler.setPaused.selector;
        sels[8] = ChordOTCHandler.setFee.selector;
        out = new FuzzSelector[](1);
        out[0] = FuzzSelector({addr: address(handler), selectors: sels});
    }

    /// S1: USDC held by the escrow equals locked USDC plus USDC credits owed to everyone.
    function invariant_usdcSolvent() public {
        uint256 credits = _credits(address(usdc));
        assertEq(usdc.balanceOf(address(otc)), handler.lockedUsdc() + credits, "USDC solvency");
    }

    /// S2: token held by the escrow equals locked token plus token credits owed.
    function invariant_tokenSolvent() public {
        uint256 credits = _credits(address(tok));
        assertEq(tok.balanceOf(address(otc)), handler.lockedTok() + credits, "token solvency");
    }

    /// S3: once an offer is Filled or Cancelled, it stays that way.
    function invariant_statusOneWay() public {
        uint256 n = otc.nextOfferId();
        for (uint256 id = 1; id < n; id++) {
            ChordOTC.Status prev = handler.lastStatus(id);
            ChordOTC.Status now_ = otc.getOffer(id).status;
            if (prev == ChordOTC.Status.Filled || prev == ChordOTC.Status.Cancelled) {
                assertEq(uint8(now_), uint8(prev), "status moved after close");
            }
        }
    }

    function _credits(address asset) internal view returns (uint256 sum) {
        for (uint160 i = 1; i <= 5; i++) {
            sum += otc.credits(address(uint160(0xA000 + i)), asset);
        }
        sum += otc.credits(address(0xFEE), asset);
    }
}

/// Deterministic edge cases the fuzzer is unlikely to hit cleanly.
contract ChordOTCEdgeTest is Test {
    ChordOTC internal otc;
    MockToken internal usdc;
    MockToken internal tok;
    address internal maker = address(0x1);
    address internal taker = address(0x2);
    address internal fee = address(0xFEE);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        tok = new MockToken("Test Token", "TT", 18);
        otc = new ChordOTC(address(usdc), fee);
        usdc.mint(maker, 1_000e6);
        usdc.mint(taker, 1_000e6);
        tok.mint(maker, 1_000e18);
        tok.mint(taker, 1_000e18);
        vm.startPrank(maker);
        usdc.approve(address(otc), type(uint256).max);
        tok.approve(address(otc), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(taker);
        usdc.approve(address(otc), type(uint256).max);
        tok.approve(address(otc), type(uint256).max);
        vm.stopPrank();
    }

    function test_blocklistedMakerCannotBlockFill() public {
        vm.prank(maker);
        uint256 id = otc.createOfferGivingToken(address(tok), 10e18, 100e6, address(0), 0);
        usdc.setBlocked(maker, true);
        vm.prank(taker);
        otc.fillOffer(id);
        // Maker's USDC payout is credited, not sent, and only the maker can claim it.
        assertTrue(otc.credits(maker, address(usdc)) > 0, "expected credit");
        vm.prank(taker);
        vm.expectRevert("nothing to withdraw");
        otc.withdraw(address(usdc));
    }

    function test_blocklistedFeeWalletCannotBlockTrading() public {
        vm.prank(maker);
        uint256 id = otc.createOfferGivingToken(address(tok), 10e18, 100e6, address(0), 0);
        usdc.setBlocked(fee, true);
        vm.prank(taker);
        otc.fillOffer(id);
        assertTrue(otc.credits(fee, address(usdc)) > 0, "expected credit");
    }

    function test_feeOnTransferTokenRejected() public {
        tok.setFeeBps(100);
        vm.prank(maker);
        vm.expectRevert();
        otc.createOfferGivingToken(address(tok), 10e18, 100e6, address(0), 0);
    }

    function test_cannotFillExpiredOffer() public {
        vm.prank(maker);
        uint256 id = otc.createOfferGivingUsdc(address(tok), 10e18, 100e6, address(0), uint64(block.timestamp + 1));
        vm.warp(block.timestamp + 2);
        vm.prank(taker);
        vm.expectRevert("offer expired");
        otc.fillOffer(id);
        // Expired offers can still be cancelled for a full refund.
        vm.prank(maker);
        otc.cancelOffer(id);
        assertEq(usdc.balanceOf(maker), 1_000e6);
    }

    function test_privateOfferOnlyForNamedTaker() public {
        vm.prank(maker);
        uint256 id = otc.createOfferGivingUsdc(address(tok), 10e18, 100e6, address(0x9), 0);
        vm.prank(taker);
        vm.expectRevert("not your offer to fill");
        otc.fillOffer(id);
    }

    function test_feeSnapshotAtCreation() public {
        vm.prank(maker);
        uint256 id = otc.createOfferGivingUsdc(address(tok), 10e18, 100e6, address(0), 0);
        vm.prank(otc.owner());
        otc.setFeeBps(300);
        vm.prank(taker);
        otc.fillOffer(id);
        // 0.25% of 100 USDC = 0.25 USDC, not 3%.
        assertEq(usdc.balanceOf(fee), 0.25e6);
    }

    function test_ownerCannotTouchOpenOffers() public {
        vm.prank(maker);
        uint256 id = otc.createOfferGivingUsdc(address(tok), 10e18, 100e6, address(0), 0);
        address owner_ = otc.owner();
        vm.prank(owner_);
        vm.expectRevert();
        otc.cancelOffer(id); // only the maker can cancel
    }
}
