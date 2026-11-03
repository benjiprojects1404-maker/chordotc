// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {ChordOTC} from "../../contracts/ChordOTC.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address, uint256) external returns (bool);
}

/// Arc's blocklist lives in a system precompile that Arc USDC calls on every transfer.
/// It only exists in Arc's own node, so on a Foundry fork we answer for it with vm.mockCall.
interface IArcBlocklist {
    function isBlocklisted(address) external view returns (bool);
}

/// Fork tests against Arc mainnet: the live ChordOTC and the real USDC and EURC contracts.
/// Everything runs on a local copy of the chain; nothing is sent to Arc.
///
/// Run:  forge test --match-contract ChordOTCForkTest --fork-url https://rpc.mainnet.arc.io -vv
/// Without --fork-url these tests are skipped, so a plain `forge test` stays offline.
contract ChordOTCForkTest is Test {
    uint256 constant ARC_CHAIN_ID = 5042;

    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    ChordOTC constant LIVE = ChordOTC(0x112a05D335c36881887568Ce924CcaEB0c52F097);
    address constant SAFE = 0xc3FC2A5D1E7e2F5d597bE891e4BC36F117D9d4B6;
    address constant ARC_BLOCKLIST = 0x1800000000000000000000000000000000000001;

    address maker = makeAddr("maker");
    address taker = makeAddr("taker");

    function setUp() public {
        if (block.chainid != ARC_CHAIN_ID) vm.skip(true);
        // Default answer from Arc's blocklist precompile: nobody is blocklisted.
        vm.mockCall(ARC_BLOCKLIST, abi.encodeWithSelector(IArcBlocklist.isBlocklisted.selector), abi.encode(false));
    }

    // ---------------------------------------------------------------------
    // 1. The live deployment is wired the way MAINNET.md says
    // ---------------------------------------------------------------------

    function test_liveDeploymentConfig() public view {
        assertGt(address(LIVE).code.length, 0, "ChordOTC has no code at the live address");
        assertEq(LIVE.usdc(), USDC, "usdc() is not Arc USDC");
        assertEq(LIVE.owner(), SAFE, "owner is not the Treasury Safe");
        assertEq(LIVE.feeRecipient(), SAFE, "fee recipient is not the Treasury Safe");
        assertLe(LIVE.feeBps(), LIVE.MAX_FEE_BPS(), "fee above the hard cap");
        assertEq(LIVE.pendingOwner(), address(0), "an ownership transfer is pending");
        // Beta caps must be in place for both stablecoins.
        assertGt(LIVE.maxOfferAmount(USDC), 0, "no USDC cap set");
        assertGt(LIVE.maxOfferAmount(EURC), 0, "no EURC cap set");
        console2.log("feeBps", LIVE.feeBps());
        console2.log("USDC cap (6 dp)", LIVE.maxOfferAmount(USDC));
        console2.log("EURC cap (6 dp)", LIVE.maxOfferAmount(EURC));
        console2.log("paused", LIVE.paused());
        console2.log("offers so far", LIVE.totalOffers());
    }

    function test_realTokensUseSixDecimals() public view {
        assertGt(USDC.code.length, 0, "no code at Arc USDC");
        assertGt(EURC.code.length, 0, "no code at EURC");
        assertEq(IERC20(USDC).decimals(), 6, "USDC ERC-20 interface is not 6 decimals");
        assertEq(IERC20(EURC).decimals(), 6, "EURC is not 6 decimals");
    }

    // ---------------------------------------------------------------------
    // 2. Trades on the live contract with the real tokens
    // ---------------------------------------------------------------------

    function test_roundTrip_makerSellsEurcForUsdc() public {
        require(!LIVE.paused(), "live contract is paused for new offers");
        uint256 amt = _underCap(EURC, 50e6);
        uint256 price = _underCap(USDC, 50e6);
        _fund(EURC, maker, amt);
        _fund(USDC, taker, price);

        vm.startPrank(maker);
        IERC20(EURC).approve(address(LIVE), amt);
        uint256 id = LIVE.createOfferGivingToken(EURC, amt, price, address(0), 0);
        vm.stopPrank();

        uint256 safeBefore = IERC20(USDC).balanceOf(SAFE);
        vm.startPrank(taker);
        IERC20(USDC).approve(address(LIVE), price);
        LIVE.fillOffer(id);
        vm.stopPrank();

        ChordOTC.Offer memory o = LIVE.getOffer(id);
        uint256 fee = (price * o.feeBpsAtCreation) / 10_000;
        assertEq(IERC20(EURC).balanceOf(taker), amt, "taker did not get the EURC");
        assertEq(IERC20(USDC).balanceOf(maker), price - fee, "maker did not get USDC minus fee");
        assertEq(IERC20(USDC).balanceOf(SAFE) - safeBefore, fee, "Safe did not get the fee");
        assertEq(uint8(o.status), uint8(ChordOTC.Status.Filled));
    }

    function test_cancelRefundsExactly() public {
        require(!LIVE.paused(), "live contract is paused for new offers");
        uint256 amt = _underCap(USDC, 25e6);
        _fund(USDC, maker, amt);

        vm.startPrank(maker);
        IERC20(USDC).approve(address(LIVE), amt);
        uint256 id = LIVE.createOfferGivingUsdc(EURC, 20e6, amt, address(0), 0);
        assertEq(IERC20(USDC).balanceOf(maker), 0);
        LIVE.cancelOffer(id);
        vm.stopPrank();

        assertEq(IERC20(USDC).balanceOf(maker), amt, "refund not exact");
    }

    function test_capIsEnforcedOnLiveContract() public {
        uint256 cap = LIVE.maxOfferAmount(EURC);
        _fund(EURC, maker, cap + 1);
        vm.startPrank(maker);
        IERC20(EURC).approve(address(LIVE), cap + 1);
        vm.expectRevert("exceeds per-offer cap");
        LIVE.createOfferGivingToken(EURC, cap + 1, 1e6, address(0), 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // 3. Arc's USDC blocklist: a blocklisted maker cannot block a fill
    // ---------------------------------------------------------------------

    function test_arcBlocklist_makerPayoutIsCredited() public {
        require(!LIVE.paused(), "live contract is paused for new offers");
        uint256 amt = _underCap(EURC, 30e6);
        uint256 price = _underCap(USDC, 30e6);
        _fund(EURC, maker, amt);
        _fund(USDC, taker, price);

        vm.startPrank(maker);
        IERC20(EURC).approve(address(LIVE), amt);
        uint256 id = LIVE.createOfferGivingToken(EURC, amt, price, address(0), 0);
        vm.stopPrank();

        // The maker is blocklisted on USDC after the offer is created.
        vm.mockCall(ARC_BLOCKLIST, abi.encodeCall(IArcBlocklist.isBlocklisted, (maker)), abi.encode(true));

        vm.startPrank(taker);
        IERC20(USDC).approve(address(LIVE), price);
        LIVE.fillOffer(id); // must not revert
        vm.stopPrank();

        uint256 fee = (price * LIVE.getOffer(id).feeBpsAtCreation) / 10_000;
        assertEq(IERC20(EURC).balanceOf(taker), amt, "taker did not get the EURC");
        assertEq(IERC20(USDC).balanceOf(maker), 0, "blocklisted maker was paid directly");
        assertEq(LIVE.credits(maker, USDC), price - fee, "maker payout not credited");

        // The taker cannot claim the maker's credit, and the maker can't withdraw while blocklisted.
        vm.prank(taker);
        vm.expectRevert("nothing to withdraw");
        LIVE.withdraw(USDC);
        vm.prank(maker);
        vm.expectRevert("token transfer failed");
        LIVE.withdraw(USDC);

        // Once un-blocklisted, the maker can claim it.
        vm.mockCall(ARC_BLOCKLIST, abi.encodeCall(IArcBlocklist.isBlocklisted, (maker)), abi.encode(false));
        vm.prank(maker);
        LIVE.withdraw(USDC);
        assertEq(IERC20(USDC).balanceOf(maker), price - fee, "maker could not claim the credit");
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// Gives `who` exactly `amt` of `token` on the fork. Arc USDC's ERC-20 balance (6 dp) is the
    /// native gas balance (18 dp), so it is set with vm.deal; EURC is an ordinary token, set with deal.
    function _fund(address token, address who, uint256 amt) internal {
        if (token == USDC) vm.deal(who, amt * 1e12);
        else deal(token, who, amt);
        require(IERC20(token).balanceOf(who) == amt, "could not fund test account");
    }

    function _underCap(address asset, uint256 want) internal view returns (uint256) {
        uint256 cap = LIVE.maxOfferAmount(asset);
        return cap == 0 || want <= cap ? want : cap;
    }
}
