// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ChordOTCv2} from "../../contracts/ChordOTCv2.sol";
import {ArcBlocklistStub, ArcNativeTransferStub} from "./ChordOTC.fork.t.sol";

interface IERC20v2 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// Fork tests for ChordOTCv2 against Arc mainnet with the real USDC and EURC contracts.
/// v2 isn't deployed yet, so each test deploys a fresh copy on a local copy of the chain; nothing is sent to Arc.
/// Arc's two system precompiles (blocklist and native transfer) are stood in for, as in ChordOTC.fork.t.sol.
///
/// Run:  forge test --match-contract ChordOTCv2ForkTest --fork-url https://rpc.mainnet.arc.io -vv
/// Without --fork-url these tests are skipped.
contract ChordOTCv2ForkTest is Test {
    uint256 constant ARC_CHAIN_ID = 5042;
    address constant USDC = 0x3600000000000000000000000000000000000000;
    address constant EURC = 0xbEf5f6d51CB62b58e6A8f77868681825C6fe21c1;
    address constant SAFE = 0xc3FC2A5D1E7e2F5d597bE891e4BC36F117D9d4B6;
    address constant ARC_BLOCKLIST = 0x1800000000000000000000000000000000000001;
    address constant ARC_NATIVE_TRANSFER = 0x1800000000000000000000000000000000000000;

    ChordOTCv2 chord;
    address maker = makeAddr("maker");
    address taker = makeAddr("taker");

    function setUp() public {
        if (block.chainid != ARC_CHAIN_ID) vm.skip(true);
        vm.etch(ARC_BLOCKLIST, address(new ArcBlocklistStub()).code);
        vm.etch(ARC_NATIVE_TRANSFER, address(new ArcNativeTransferStub()).code);
        vm.allowCheatcodes(ARC_NATIVE_TRANSFER);
        chord = new ChordOTCv2(USDC, SAFE);
    }

    function test_makerSellsEurc_walletToWallet() public {
        _fund(EURC, maker, 50e6);
        _fund(USDC, taker, 52e6);
        vm.startPrank(maker);
        IERC20v2(EURC).approve(address(chord), 50e6);
        uint256 id = chord.createOfferGivingToken(EURC, 50e6, 52e6, address(0), 0);
        vm.stopPrank();
        assertEq(IERC20v2(EURC).balanceOf(maker), 50e6, "EURC left the maker's wallet at create");
        assertTrue(chord.offerReady(id));

        uint256 safeBefore = IERC20v2(USDC).balanceOf(SAFE);
        vm.startPrank(taker);
        IERC20v2(USDC).approve(address(chord), 52e6);
        chord.fillOffer(id);
        vm.stopPrank();

        uint256 fee = 52e6 * 25 / 10_000;
        assertEq(IERC20v2(EURC).balanceOf(taker), 50e6, "taker did not get the EURC");
        assertEq(IERC20v2(USDC).balanceOf(maker), 52e6 - fee, "maker did not get USDC minus fee");
        assertEq(IERC20v2(USDC).balanceOf(SAFE) - safeBefore, fee, "Safe did not get the fee");
        _holdsNothing();
    }

    function test_makerSellsUsdc_walletToWallet() public {
        _fund(USDC, maker, 40e6);
        _fund(EURC, taker, 37e6);
        vm.startPrank(maker);
        IERC20v2(USDC).approve(address(chord), 40e6);
        uint256 id = chord.createOfferGivingUsdc(EURC, 37e6, 40e6, address(0), 0);
        vm.stopPrank();
        assertEq(IERC20v2(USDC).balanceOf(maker), 40e6, "USDC left the maker's wallet at create");

        vm.startPrank(taker);
        IERC20v2(EURC).approve(address(chord), 37e6);
        chord.fillOffer(id);
        vm.stopPrank();

        uint256 fee = 40e6 * 25 / 10_000;
        assertEq(IERC20v2(EURC).balanceOf(maker), 37e6);
        assertEq(IERC20v2(USDC).balanceOf(taker), 40e6 - fee);
        assertEq(IERC20v2(USDC).balanceOf(maker), 0);
        _holdsNothing();
    }

    function test_makerSpendsUsdcAfterPosting_fillFailsCleanly() public {
        _fund(USDC, maker, 20e6);
        _fund(EURC, taker, 18e6);
        vm.startPrank(maker);
        IERC20v2(USDC).approve(address(chord), 20e6);
        uint256 id = chord.createOfferGivingUsdc(EURC, 18e6, 20e6, address(0), 0);
        IERC20v2(USDC).transfer(makeAddr("elsewhere"), 10e6);
        vm.stopPrank();
        assertFalse(chord.offerReady(id), "site would still show the offer as ready");

        vm.startPrank(taker);
        IERC20v2(EURC).approve(address(chord), 18e6);
        vm.expectRevert();
        chord.fillOffer(id);
        vm.stopPrank();
        assertEq(IERC20v2(EURC).balanceOf(taker), 18e6, "taker lost EURC on a failed fill");
        _holdsNothing();
    }

    /// Arc's USDC blocklist: a blocklisted maker makes the fill fail, and nobody loses anything
    /// (v1 credited the payout instead, which meant the contract held it).
    function test_arcBlocklist_fillRevertsAndNothingMoves() public {
        _fund(EURC, maker, 30e6);
        _fund(USDC, taker, 30e6);
        vm.startPrank(maker);
        IERC20v2(EURC).approve(address(chord), 30e6);
        uint256 id = chord.createOfferGivingToken(EURC, 30e6, 30e6, address(0), 0);
        vm.stopPrank();

        ArcBlocklistStub(ARC_BLOCKLIST).set(maker, true);
        vm.startPrank(taker);
        IERC20v2(USDC).approve(address(chord), 30e6);
        vm.expectRevert();
        chord.fillOffer(id);
        vm.stopPrank();
        assertEq(IERC20v2(EURC).balanceOf(maker), 30e6);
        assertEq(IERC20v2(USDC).balanceOf(taker), 30e6);
        _holdsNothing();

        // Once un-blocklisted, the same offer fills normally.
        ArcBlocklistStub(ARC_BLOCKLIST).set(maker, false);
        vm.prank(taker);
        chord.fillOffer(id);
        assertEq(IERC20v2(EURC).balanceOf(taker), 30e6);
        _holdsNothing();
    }

    function test_refusesNativeUsdc() public {
        vm.deal(taker, 1e18);
        vm.prank(taker);
        (bool ok, ) = address(chord).call{value: 1e18}("");
        assertFalse(ok, "contract accepted native USDC");
    }

    function _holdsNothing() internal view {
        assertEq(IERC20v2(USDC).balanceOf(address(chord)), 0, "contract holds USDC");
        assertEq(IERC20v2(EURC).balanceOf(address(chord)), 0, "contract holds EURC");
        assertEq(address(chord).balance, 0, "contract holds native USDC");
    }

    function _fund(address token, address who, uint256 amt) internal {
        if (token == USDC) vm.deal(who, amt * 1e12);
        else deal(token, who, amt);
        require(IERC20v2(token).balanceOf(who) == amt, "could not fund test account");
    }
}
