// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {ChordOTC} from "../../contracts/ChordOTC.sol";
import {ChordOTCv2} from "../../contracts/ChordOTCv2.sol";
import {MockToken} from "../Mocks.sol";

/// Configurable misbehaving ERC-20 used only in this review suite.
contract FlexToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public surchargeBps; // sender pays extra on transferFrom (receiver gets exact amount)
    uint256 public outExtraBps; // sender pays extra on transfer()
    uint256 public outShortBps; // recipient short-paid on transfer() (sender debited exactly amount)

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function setBalance(address a, uint256 v) external { balanceOf[a] = v; }
    function setSurcharge(uint256 b) external { surchargeBps = b; }
    function setOutExtra(uint256 b) external { outExtraBps = b; }
    function setOutShort(uint256 b) external { outShortBps = b; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 a) external returns (bool) {
        uint256 extra = a * outExtraBps / 10_000;
        uint256 short = a * outShortBps / 10_000;
        require(balanceOf[msg.sender] >= a + extra, "balance");
        balanceOf[msg.sender] -= a + extra;
        balanceOf[to] += a - short;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a, "allowance");
        uint256 extra = a * surchargeBps / 10_000;
        require(balanceOf[f] >= a + extra, "balance");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a + extra;
        balanceOf[t] += a;
        return true;
    }
}

/// Well-behaved ERC-20 whose transfer/transferFrom return a ~20 KB blob (first word = true).
contract HugeReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        assembly { mstore(0, 1) return(0, 20000) }
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        assembly { mstore(0, 1) return(0, 20000) }
    }
}

contract ChordOTCReviewBase is Test {
    event PausedSet(bool isPaused);

    ChordOTC c1;
    ChordOTCv2 c2;
    MockToken usdc;
    MockToken tok;
    FlexToken flex;
    HugeReturnToken huge;

    address treasury = makeAddr("treasury");
    address maker = makeAddr("maker");
    address taker = makeAddr("taker");
    address other = makeAddr("other");

    uint256 constant U = 1_000e6;
    uint256 constant T = 500e18;
    string constant FEE_MSG = "token took a transfer fee or rebased - unsupported";

    function setUp() public virtual {
        usdc = new MockToken("USD Coin", "USDC", 6);
        tok = new MockToken("Token", "TOK", 18);
        flex = new FlexToken();
        huge = new HugeReturnToken();
        c1 = new ChordOTC(address(usdc), treasury);
        c2 = new ChordOTCv2(address(usdc), treasury);
        for (uint256 i; i < 3; i++) {
            address a = [maker, taker, other][i];
            usdc.mint(a, 1_000_000e6);
            tok.mint(a, 1_000_000e18);
            flex.mint(a, 1_000_000e18);
            huge.mint(a, 1_000_000e18);
            vm.startPrank(a);
            address[2] memory cs = [address(c1), address(c2)];
            for (uint256 j; j < 2; j++) {
                usdc.approve(cs[j], type(uint256).max);
                tok.approve(cs[j], type(uint256).max);
                flex.approve(cs[j], type(uint256).max);
                huge.approve(cs[j], type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    function _g1U(address t, uint256 aT, uint256 aU) internal returns (uint256) {
        vm.prank(maker);
        return c1.createOfferGivingUsdc(t, aT, aU, address(0), 0);
    }

    function _g1T(address t, uint256 aT, uint256 aU) internal returns (uint256) {
        vm.prank(maker);
        return c1.createOfferGivingToken(t, aT, aU, address(0), 0);
    }

    function _g2U(address t, uint256 aT, uint256 aU) internal returns (uint256) {
        vm.prank(maker);
        return c2.createOfferGivingUsdc(t, aT, aU, address(0), 0);
    }

    function _g2T(address t, uint256 aT, uint256 aU) internal returns (uint256) {
        vm.prank(maker);
        return c2.createOfferGivingToken(t, aT, aU, address(0), 0);
    }

    function _fill1(uint256 id) internal { vm.prank(taker); c1.fillOffer(id); }
    function _fill2(uint256 id) internal { vm.prank(taker); c2.fillOffer(id); }
    function _cancel1(uint256 id) internal { vm.prank(maker); c1.cancelOffer(id); }
    function _cancel2(uint256 id) internal { vm.prank(maker); c2.cancelOffer(id); }
    function _st1(uint256 id) internal view returns (ChordOTC.Status) { return c1.getOffer(id).status; }
    function _st2(uint256 id) internal view returns (ChordOTCv2.Status) { return c2.getOffer(id).status; }
}

contract ChordOTCReviewTest is ChordOTCReviewBase {
    // ===================== F-01 sender-side surcharge =====================

    function test_F01_v1_create_tokenGiving_senderSurchargeRejected() public {
        flex.setSurcharge(100);
        vm.prank(maker);
        vm.expectRevert(bytes(FEE_MSG));
        c1.createOfferGivingToken(address(flex), T, U, address(0), 0);
    }

    function test_F01_v1_fill_takerPaysToken_senderSurchargeRejected() public {
        uint256 id = _g1U(address(flex), T, U);
        flex.setSurcharge(100);
        vm.prank(taker);
        vm.expectRevert(bytes(FEE_MSG));
        c1.fillOffer(id);
        assertEq(uint256(_st1(id)), uint256(ChordOTC.Status.Open));
    }

    function test_F01_v2_fill_takerPaysToken_senderSurchargeRejected() public {
        uint256 id = _g2U(address(flex), T, U);
        flex.setSurcharge(100);
        vm.prank(taker);
        vm.expectRevert(bytes(FEE_MSG));
        c2.fillOffer(id);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Open));
    }

    function test_F01_v2_fill_makerPaysToken_senderSurchargeRejected() public {
        uint256 id = _g2T(address(flex), T, U);
        flex.setSurcharge(100);
        vm.prank(taker);
        vm.expectRevert(bytes(FEE_MSG));
        c2.fillOffer(id);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Open));
    }

    // ===================== F-01 outgoing tax from v1 escrow =====================

    function test_F01_v1_cancel_escrowOverDebited_reverts() public {
        uint256 id = _g1T(address(flex), T, U);
        flex.setOutExtra(1000);
        flex.mint(address(c1), T); // buffer so the token itself does not underflow
        vm.prank(maker);
        vm.expectRevert(bytes(FEE_MSG));
        c1.cancelOffer(id);
        assertEq(uint256(_st1(id)), uint256(ChordOTC.Status.Open));
    }

    function test_F01_v1_fill_escrowOverDebited_reverts() public {
        uint256 id = _g1T(address(flex), T, U);
        flex.setOutExtra(1000);
        flex.mint(address(c1), T);
        vm.prank(taker);
        vm.expectRevert(bytes(FEE_MSG));
        c1.fillOffer(id);
        assertEq(uint256(_st1(id)), uint256(ChordOTC.Status.Open));
    }

    /// Escrow is debited exactly `amount` but the recipient is short-paid. Spec says this must revert.
    function test_F01_v1_cancel_recipientShortPaid_reverts() public {
        uint256 id = _g1T(address(flex), T, U);
        flex.setOutShort(1000);
        vm.prank(maker);
        vm.expectRevert();
        c1.cancelOffer(id);
    }

    function test_F01_v1_fill_recipientShortPaid_reverts() public {
        uint256 id = _g1T(address(flex), T, U);
        flex.setOutShort(1000);
        vm.prank(taker);
        vm.expectRevert();
        c1.fillOffer(id);
    }

    // ===================== F-01 plain token + USDC unchanged =====================

    function test_F01_v1_usdcLegsUnchanged() public {
        uint256 mu = usdc.balanceOf(maker);
        uint256 tu = usdc.balanceOf(taker);
        uint256 id = _g1U(address(tok), T, U);
        assertEq(usdc.balanceOf(address(c1)), U);
        _fill1(id);
        uint256 fee = U * 25 / 10_000;
        assertEq(usdc.balanceOf(maker), mu - U);
        assertEq(usdc.balanceOf(taker), tu + U - fee);
        assertEq(usdc.balanceOf(treasury), fee);
        id = _g1T(address(tok), T, U);
        _fill1(id);
        assertEq(usdc.balanceOf(maker), mu - U + U - fee);
        assertEq(usdc.balanceOf(address(c1)), 0);
        assertEq(tok.balanceOf(address(c1)), 0);
    }

    function test_F01_v2_usdcLegsUnchanged() public {
        uint256 mu = usdc.balanceOf(maker);
        uint256 tu = usdc.balanceOf(taker);
        uint256 id = _g2U(address(tok), T, U);
        _fill2(id);
        uint256 fee = U * 25 / 10_000;
        assertEq(usdc.balanceOf(maker), mu - U);
        assertEq(usdc.balanceOf(taker), tu + U - fee);
        assertEq(usdc.balanceOf(treasury), fee);
        id = _g2T(address(tok), T, U);
        _fill2(id);
        assertEq(usdc.balanceOf(maker), mu - U + U - fee);
        assertEq(usdc.balanceOf(address(c2)), 0);
    }

    function test_F01_v1_fuzz_plainTokenConserves(uint256 aT, uint256 aU, bool givesUsdc) public {
        aT = bound(aT, 1, 1_000_000e18);
        aU = bound(aU, 1, 1_000_000e6);
        uint256 mu = usdc.balanceOf(maker); uint256 mt = tok.balanceOf(maker);
        uint256 tu = usdc.balanceOf(taker); uint256 tt = tok.balanceOf(taker);
        uint256 id = givesUsdc ? _g1U(address(tok), aT, aU) : _g1T(address(tok), aT, aU);
        _fill1(id);
        uint256 fee = aU * 25 / 10_000;
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(address(c1)), 0);
        assertEq(tok.balanceOf(address(c1)), 0);
        assertEq(usdc.balanceOf(maker) + usdc.balanceOf(taker) + fee, mu + tu);
        assertEq(tok.balanceOf(maker) + tok.balanceOf(taker), mt + tt);
        if (givesUsdc) {
            assertEq(usdc.balanceOf(taker), tu + aU - fee);
            assertEq(tok.balanceOf(maker), mt + aT);
        } else {
            assertEq(usdc.balanceOf(maker), mu + aU - fee);
            assertEq(tok.balanceOf(taker), tt + aT);
        }
    }

    function test_F01_v1_fuzz_plainTokenCancelRoundTrips(uint256 aT, uint256 aU, bool givesUsdc) public {
        aT = bound(aT, 1, 1_000_000e18);
        aU = bound(aU, 1, 1_000_000e6);
        uint256 mu = usdc.balanceOf(maker); uint256 mt = tok.balanceOf(maker);
        uint256 id = givesUsdc ? _g1U(address(tok), aT, aU) : _g1T(address(tok), aT, aU);
        _cancel1(id);
        assertEq(usdc.balanceOf(maker), mu);
        assertEq(tok.balanceOf(maker), mt);
        assertEq(usdc.balanceOf(address(c1)), 0);
        assertEq(tok.balanceOf(address(c1)), 0);
    }

    function test_F01_v2_fuzz_plainTokenConserves(uint256 aT, uint256 aU, bool givesUsdc) public {
        aT = bound(aT, 1, 1_000_000e18);
        aU = bound(aU, 1, 1_000_000e6);
        uint256 mu = usdc.balanceOf(maker); uint256 mt = tok.balanceOf(maker);
        uint256 tu = usdc.balanceOf(taker); uint256 tt = tok.balanceOf(taker);
        uint256 id = givesUsdc ? _g2U(address(tok), aT, aU) : _g2T(address(tok), aT, aU);
        _fill2(id);
        uint256 fee = aU * 25 / 10_000;
        assertEq(usdc.balanceOf(treasury), fee);
        assertEq(usdc.balanceOf(address(c2)), 0);
        assertEq(tok.balanceOf(address(c2)), 0);
        assertEq(usdc.balanceOf(maker) + usdc.balanceOf(taker) + fee, mu + tu);
        assertEq(tok.balanceOf(maker) + tok.balanceOf(taker), mt + tt);
        if (givesUsdc) {
            assertEq(usdc.balanceOf(taker), tu + aU - fee);
            assertEq(tok.balanceOf(maker), mt + aT);
        } else {
            assertEq(usdc.balanceOf(maker), mu + aU - fee);
            assertEq(tok.balanceOf(taker), tt + aT);
        }
    }

    // ===================== F-02 rebase down after deposit (v1) =====================

    function test_F02_v1_rebaseDownAfterDeposit_cancelReverts() public {
        uint256 id = _g1T(address(flex), T, U);
        assertEq(flex.balanceOf(address(c1)), T);
        flex.setBalance(address(c1), T / 2); // rebase down: escrow now short
        vm.prank(maker);
        vm.expectRevert(bytes("token transfer failed"));
        c1.cancelOffer(id);
        // Whole tx reverted: offer still Open, maker's tokens stuck.
        assertEq(uint256(_st1(id)), uint256(ChordOTC.Status.Open));
    }

    // ===================== F-03 escrow blocked by USDC (v1) =====================

    function test_F03_v1_blockedEscrow_cancelUsdcOfferReverts() public {
        uint256 id = _g1U(address(tok), T, U);
        usdc.setBlocked(address(c1), true);
        vm.prank(maker);
        vm.expectRevert();
        c1.cancelOffer(id);
        assertEq(uint256(_st1(id)), uint256(ChordOTC.Status.Open));
    }

    function test_F03_v1_blockedEscrow_fillReverts() public {
        uint256 idU = _g1U(address(tok), T, U);
        uint256 idT = _g1T(address(tok), T, U);
        usdc.setBlocked(address(c1), true);
        vm.prank(taker);
        vm.expectRevert();
        c1.fillOffer(idU); // escrow cannot pay out USDC
        vm.prank(taker);
        vm.expectRevert();
        c1.fillOffer(idT); // escrow cannot receive USDC
    }

    function test_F03_v1_blockedEscrow_withdrawReverts() public {
        uint256 id = _g1T(address(tok), T, U);
        usdc.setBlocked(maker, true);
        _fill1(id); // maker blocked -> proceeds credited
        uint256 credit = c1.credits(maker, address(usdc));
        assertEq(credit, U - U * 25 / 10_000);
        usdc.setBlocked(maker, false);
        usdc.setBlocked(address(c1), true);
        vm.prank(maker);
        vm.expectRevert();
        c1.withdraw(address(usdc));
        assertEq(c1.credits(maker, address(usdc)), credit); // credit preserved
    }

    // ===================== F-04 blocked fee recipient (v2) =====================

    function test_F04_v2_blockedFeeRecipient_fillReverts() public {
        uint256 idU = _g2U(address(tok), T, U);
        uint256 idT = _g2T(address(tok), T, U);
        usdc.setBlocked(treasury, true);
        vm.prank(taker);
        vm.expectRevert();
        c2.fillOffer(idU);
        vm.prank(taker);
        vm.expectRevert();
        c2.fillOffer(idT);
        assertEq(uint256(_st2(idU)), uint256(ChordOTCv2.Status.Open));
        assertEq(uint256(_st2(idT)), uint256(ChordOTCv2.Status.Open));
    }

    function test_F04_v2_ownerSetFeeRecipient_restoresFills() public {
        uint256 id = _g2T(address(tok), T, U);
        usdc.setBlocked(treasury, true);
        vm.prank(taker);
        vm.expectRevert();
        c2.fillOffer(id);
        address clean = makeAddr("cleanTreasury");
        c2.setFeeRecipient(clean);
        _fill2(id);
        assertEq(usdc.balanceOf(clean), U * 25 / 10_000);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Filled));
    }

    function test_F04_v2_zeroFeeSnapshot_stillFillsWithBlockedRecipient() public {
        c2.setFeeBps(0);
        uint256 idT = _g2T(address(tok), T, U);
        uint256 idU = _g2U(address(tok), T, U);
        usdc.setBlocked(treasury, true);
        _fill2(idT);
        _fill2(idU);
        assertEq(uint256(_st2(idT)), uint256(ChordOTCv2.Status.Filled));
        assertEq(uint256(_st2(idU)), uint256(ChordOTCv2.Status.Filled));
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // ===================== F-05 fee recipient validation =====================

    function test_F05_v1_constructor_rejectsZeroAndSelf() public {
        vm.expectRevert(bytes("bad fee recipient"));
        new ChordOTC(address(usdc), address(0));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(bytes("bad fee recipient"));
        new ChordOTC(address(usdc), predicted);
    }

    function test_F05_v2_constructor_rejectsZeroAndSelf() public {
        vm.expectRevert(bytes("bad fee recipient"));
        new ChordOTCv2(address(usdc), address(0));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(bytes("bad fee recipient"));
        new ChordOTCv2(address(usdc), predicted);
    }

    function test_F05_v1_setFeeRecipient_rejectsZeroAndSelf() public {
        vm.expectRevert(bytes("bad recipient"));
        c1.setFeeRecipient(address(0));
        vm.expectRevert(bytes("bad recipient"));
        c1.setFeeRecipient(address(c1));
        c1.setFeeRecipient(other);
        assertEq(c1.feeRecipient(), other);
    }

    function test_F05_v2_setFeeRecipient_rejectsZeroAndSelf() public {
        vm.expectRevert(bytes("bad recipient"));
        c2.setFeeRecipient(address(0));
        vm.expectRevert(bytes("bad recipient"));
        c2.setFeeRecipient(address(c2));
        c2.setFeeRecipient(other);
        assertEq(c2.feeRecipient(), other);
    }

    // ===================== F-06 token code removed after creation =====================

    function test_F06_v1_fill_makerGaveToken_codeRemoved_reverts() public {
        uint256 id = _g1T(address(tok), T, U);
        vm.etch(address(tok), "");
        vm.prank(taker);
        vm.expectRevert();
        c1.fillOffer(id);
        assertEq(uint256(_st1(id)), uint256(ChordOTC.Status.Open));
    }

    function test_F06_v1_cancel_makerGaveToken_codeRemoved_reverts() public {
        uint256 id = _g1T(address(tok), T, U);
        vm.etch(address(tok), "");
        vm.prank(maker);
        vm.expectRevert();
        c1.cancelOffer(id);
        assertEq(uint256(_st1(id)), uint256(ChordOTC.Status.Open));
    }

    function test_F06_v2_fill_makerGivesToken_codeRemoved_reverts() public {
        uint256 id = _g2T(address(tok), T, U);
        vm.etch(address(tok), "");
        vm.prank(taker);
        vm.expectRevert();
        c2.fillOffer(id);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Open));
    }

    // ===================== F-07 huge returndata =====================

    function test_F07_v1_hugeReturndata_fillAndCancelConsistent() public {
        uint256 idF = _g1T(address(huge), T, U);
        uint256 idC = _g1T(address(huge), T, U);
        uint256 mt = huge.balanceOf(maker);
        uint256 tt = huge.balanceOf(taker);
        _fill1(idF);
        assertEq(uint256(_st1(idF)), uint256(ChordOTC.Status.Filled));
        assertEq(huge.balanceOf(taker), tt + T);
        _cancel1(idC);
        assertEq(uint256(_st1(idC)), uint256(ChordOTC.Status.Cancelled));
        assertEq(huge.balanceOf(maker), mt + T);
        assertEq(huge.balanceOf(address(c1)), 0);
        // token-paying taker direction
        uint256 idU = _g1U(address(huge), T, U);
        _fill1(idU);
        assertEq(uint256(_st1(idU)), uint256(ChordOTC.Status.Filled));
        assertEq(huge.balanceOf(address(c1)), 0);
    }

    function test_F07_v2_hugeReturndata_fillConsistent() public {
        uint256 idT = _g2T(address(huge), T, U);
        uint256 idU = _g2U(address(huge), T, U);
        uint256 mt = huge.balanceOf(maker);
        uint256 tt = huge.balanceOf(taker);
        _fill2(idT);
        assertEq(huge.balanceOf(maker), mt - T);
        assertEq(huge.balanceOf(taker), tt + T);
        _fill2(idU);
        assertEq(huge.balanceOf(maker), mt);
        assertEq(huge.balanceOf(taker), tt);
        assertEq(uint256(_st2(idT)), uint256(ChordOTCv2.Status.Filled));
        assertEq(uint256(_st2(idU)), uint256(ChordOTCv2.Status.Filled));
    }

    // ===================== F-08 fee rounds to zero =====================

    function test_F08_v1_tinyAmount_feeZero() public {
        uint256 aU = 399; // 399 * 25 / 10000 == 0
        uint256 idT = _g1T(address(tok), T, aU);
        uint256 mu = usdc.balanceOf(maker);
        vm.recordLogs();
        _fill1(idT);
        assertEq(usdc.balanceOf(maker), mu + aU);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(c1.credits(treasury, address(usdc)), 0);
        uint256 idU = _g1U(address(tok), T, aU);
        uint256 tu = usdc.balanceOf(taker);
        _fill1(idU);
        assertEq(usdc.balanceOf(taker), tu + aU);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(usdc.balanceOf(address(c1)), 0);
    }

    function test_F08_v2_tinyAmount_feeZero() public {
        uint256 aU = 399;
        uint256 idT = _g2T(address(tok), T, aU);
        uint256 mu = usdc.balanceOf(maker);
        vm.expectEmit(true, true, false, true, address(c2));
        emit ChordOTCv2.OfferFilled(idT, taker, 0);
        _fill2(idT);
        assertEq(usdc.balanceOf(maker), mu + aU);
        assertEq(usdc.balanceOf(treasury), 0);
        uint256 idU = _g2U(address(tok), T, aU);
        uint256 tu = usdc.balanceOf(taker);
        _fill2(idU);
        assertEq(usdc.balanceOf(taker), tu + aU);
        assertEq(usdc.balanceOf(treasury), 0);
    }

    // ===================== F-09 maker revokes / moves funds (v2) =====================

    function test_F09_v2_makerRevokesUsdcApproval() public {
        uint256 id = _g2U(address(tok), T, U);
        assertTrue(c2.offerReady(id));
        vm.prank(maker);
        usdc.approve(address(c2), 0);
        assertFalse(c2.offerReady(id));
        vm.prank(taker);
        vm.expectRevert();
        c2.fillOffer(id);
        _cancel2(id);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Cancelled));
    }

    function test_F09_v2_makerRevokesTokenApproval() public {
        uint256 id = _g2T(address(tok), T, U);
        assertTrue(c2.offerReady(id));
        vm.prank(maker);
        tok.approve(address(c2), 0);
        assertFalse(c2.offerReady(id));
        vm.prank(taker);
        vm.expectRevert();
        c2.fillOffer(id);
        _cancel2(id);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Cancelled));
    }

    function test_F09_v2_makerMovesUsdcBalance() public {
        uint256 id = _g2U(address(tok), T, U);
        uint256 bal = usdc.balanceOf(maker);
        vm.prank(maker);
        usdc.transfer(other, bal);
        assertFalse(c2.offerReady(id));
        vm.prank(taker);
        vm.expectRevert();
        c2.fillOffer(id);
        _cancel2(id);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Cancelled));
    }

    function test_F09_v2_makerMovesTokenBalance() public {
        uint256 id = _g2T(address(tok), T, U);
        uint256 bal = tok.balanceOf(maker);
        vm.prank(maker);
        tok.transfer(other, bal);
        assertFalse(c2.offerReady(id));
        vm.prank(taker);
        vm.expectRevert();
        c2.fillOffer(id);
        _cancel2(id);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Cancelled));
    }

    // ===================== F-10 pause semantics =====================

    function test_F10_v2_pause_blocksFillAndCreate_cancelWorks() public {
        uint256 idA = _g2T(address(tok), T, U);
        uint256 idB = _g2U(address(tok), T, U);
        c2.setPaused(true);
        assertFalse(c2.offerReady(idA));
        vm.prank(taker);
        vm.expectRevert(bytes("paused"));
        c2.fillOffer(idA);
        vm.prank(maker);
        vm.expectRevert(bytes("paused"));
        c2.createOfferGivingToken(address(tok), T, U, address(0), 0);
        vm.prank(maker);
        vm.expectRevert(bytes("paused"));
        c2.createOfferGivingUsdc(address(tok), T, U, address(0), 0);
        _cancel2(idA);
        _cancel2(idB);
        assertEq(uint256(_st2(idA)), uint256(ChordOTCv2.Status.Cancelled));
        assertEq(uint256(_st2(idB)), uint256(ChordOTCv2.Status.Cancelled));
        c2.setPaused(false);
        _g2T(address(tok), T, U); // creation resumes
    }

    function test_F10_v1_pause_blocksOnlyCreate_fillAndCancelWork() public {
        uint256 idA = _g1T(address(tok), T, U);
        uint256 idB = _g1U(address(tok), T, U);
        c1.setPaused(true);
        vm.prank(maker);
        vm.expectRevert(bytes("offers paused"));
        c1.createOfferGivingToken(address(tok), T, U, address(0), 0);
        vm.prank(maker);
        vm.expectRevert(bytes("offers paused"));
        c1.createOfferGivingUsdc(address(tok), T, U, address(0), 0);
        _fill1(idA);
        _cancel1(idB);
        assertEq(uint256(_st1(idA)), uint256(ChordOTC.Status.Filled));
        assertEq(uint256(_st1(idB)), uint256(ChordOTC.Status.Cancelled));
        assertEq(usdc.balanceOf(address(c1)), 0);
        assertEq(tok.balanceOf(address(c1)), 0);
    }

    // ===================== F-11 amountUsdc near uint256 max =====================

    function test_F11_v1_hugeAmountUsdc_fillOverflows_makerCanCancel() public {
        uint256 mt = tok.balanceOf(maker);
        uint256 id = _g1T(address(tok), T, type(uint256).max);
        vm.prank(taker);
        vm.expectRevert(stdError.arithmeticError);
        c1.fillOffer(id);
        assertEq(uint256(_st1(id)), uint256(ChordOTC.Status.Open));
        _cancel1(id);
        assertEq(uint256(_st1(id)), uint256(ChordOTC.Status.Cancelled));
        assertEq(tok.balanceOf(maker), mt);
    }

    function test_F11_v2_hugeAmountUsdc_fillOverflows_makerCanCancel() public {
        uint256 id = _g2T(address(tok), T, type(uint256).max);
        vm.prank(taker);
        vm.expectRevert(stdError.arithmeticError);
        c2.fillOffer(id);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Open));
        _cancel2(id);
        assertEq(uint256(_st2(id)), uint256(ChordOTCv2.Status.Cancelled));
    }

    // ===================== F-21 / F-22 setPaused selector =====================

    function test_F21_F22_v1_setPaused_selector_and_event() public {
        assertEq(bytes4(keccak256("setPaused(bool)")), bytes4(0x16c38b3c));
        vm.expectEmit(false, false, false, true, address(c1));
        emit PausedSet(true);
        (bool ok,) = address(c1).call(abi.encodeWithSignature("setPaused(bool)", true));
        assertTrue(ok);
        assertTrue(c1.paused());
        (ok,) = address(c1).call(abi.encodeWithSelector(bytes4(0x16c38b3c), false));
        assertTrue(ok);
        assertFalse(c1.paused());
        vm.prank(other);
        (ok,) = address(c1).call(abi.encodeWithSignature("setPaused(bool)", true));
        assertFalse(ok);
    }

    function test_F21_F22_v2_setPaused_selector_and_event() public {
        assertEq(bytes4(keccak256("setPaused(bool)")), bytes4(0x16c38b3c));
        vm.expectEmit(false, false, false, true, address(c2));
        emit PausedSet(true);
        (bool ok,) = address(c2).call(abi.encodeWithSignature("setPaused(bool)", true));
        assertTrue(ok);
        assertTrue(c2.paused());
        (ok,) = address(c2).call(abi.encodeWithSelector(bytes4(0x16c38b3c), false));
        assertTrue(ok);
        assertFalse(c2.paused());
        vm.prank(other);
        (ok,) = address(c2).call(abi.encodeWithSignature("setPaused(bool)", true));
        assertFalse(ok);
    }
}
