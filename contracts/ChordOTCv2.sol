// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * ChordOTC v2.1: peer-to-peer ERC-20 <-> USDC trades on Arc that never hold funds
 * ------------------------------------------------------------------------------
 *
 * v2.1 (after the Olympix BugPoCer scan of 19 Nov 2026)
 *  - 5.1.1: each maker's open offers are tracked per asset (`committed`). A new offer needs balance and
 *    approval for everything already committed on that asset plus the new amount, so an approval given for
 *    one offer can no longer revive an older offer that lost its backing. Fill and cancel release the
 *    commitment. An expired offer stays committed until its maker cancels it.
 *  - CHORD-02 (Proovant): filling an offer can't spend the balance or approval behind the taker's own open
 *    offers on the asset they pay with; the fill reverts unless those stay fully backed.
 *  - 5.2.1: both create functions take `maxFeeBps`; the offer reverts if the fee is above it, so a fee change
 *    landing before a pending create can't set terms the maker didn't see. OfferCreated emits the fee.
 *  - 5.2.2: the per-asset cap is a two-sided trade-size limit (as enforced since v2); docs corrected.
 *  - Includes the pre-audit review fixes F-01, F-05, F-06, F-21, F-22, F-25.
 *
 * What changed from v1 (ChordOTC.sol)
 *  v1 was an escrow: the maker's USDC or token sat in the contract until fill or cancel, and payouts that
 *  couldn't be delivered were held as credits. v2 records only the TERMS of an offer. The maker's side stays
 *  in the maker's own wallet under an ordinary ERC-20 approval until a taker fills, and a fill moves both
 *  sides (and the fee) wallet to wallet in one transaction: if any transfer fails, the whole fill reverts and
 *  nothing moves. The contract never receives, holds or forwards any funds, so there are no credits and no
 *  withdraw(). Same design as Handshake v4 on BlockDAG.
 *
 *  Kept the same as v1, so the site barely changes: function names and arguments (createOfferGivingUsdc,
 *  createOfferGivingToken, fillOffer, cancelOffer, getOffer, isFillable), the Offer struct, the events used
 *  by the site, fee snapshot per offer (0.25% default, max 3%, taken from the USDC leg), per-asset caps,
 *  two-step ownership.
 *
 * Arc notes (docs.arc.io "EVM differences")
 *  1. USDC is used only through its 6-decimal ERC-20 interface. Nothing is payable and there is no
 *     receive(), so native value can never reach the contract.
 *  2. USDC has a blocklist. A blocked maker, taker or fee recipient makes that fill revert; nobody loses
 *     anything, because nothing was deposited. (If the fee recipient were ever blocked, every fill would
 *     revert until the owner points the fee somewhere else with setFeeRecipient.)
 *  3. Arc rejects transfers to address(0): no transfer here ever goes to address(0).
 *  4. Timestamps can repeat between blocks; expiry only uses "block.timestamp > expiresAt".
 *
 * Checks
 *  - The token must have code (blocks the "no-code token" fake-payment trick).
 *  - Token legs are measured at the receiver and must arrive in full, so fee-on-transfer and rebasing
 *    tokens are refused.
 *  - Creating an offer needs the maker's balance and approval to cover all of their open offers on that
 *    asset plus the new one (no spam offers, no revived stale offers); offerReady(id) tells the site when
 *    an offer went stale later. A stale offer is not cancelled: cancel it to release it.
 *  - Pause stops new offers and fills (safe: makers keep their funds). Cancelling always works.
 */

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract ChordOTCv2 {
    enum Status {
        None,
        Open,
        Filled,
        Cancelled
    }

    struct Offer {
        address maker;
        address taker; // address(0) = open to anyone
        address token; // the non-USDC ERC-20 in the trade
        uint256 amountUsdc; // USDC amount (6 decimals)
        uint256 amountToken; // token amount (token's smallest unit)
        bool makerGivesUsdc; // true: maker gives USDC and wants token; false: the reverse
        Status status;
        uint64 createdAt;
        uint64 expiresAt; // 0 = no expiry
        uint16 feeBpsAtCreation;
    }

    address public immutable usdc;

    address public owner;
    address public pendingOwner;
    address public feeRecipient;

    uint16 public feeBps = 25; // 0.25%
    uint16 public constant MAX_FEE_BPS = 300; // 3%

    bool public paused;
    uint256 private _locked = 1;

    /// @notice Optional per-asset trade-size limit for new offers (0 = uncapped). Applied to BOTH legs of a new
    ///         offer: the asset given and the asset wanted. v2 holds neither leg, so the cap limits the size of
    ///         any single trade during the beta, whichever side it is measured on.
    mapping(address => uint256) public maxOfferAmount;

    /// @notice maker => asset => total amount promised by the maker's Open offers that give that asset.
    mapping(address => mapping(address => uint256)) public committed;

    uint256 public nextOfferId = 1;
    mapping(uint256 => Offer) public offers;

    event OfferCreated(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        address token,
        uint256 amountUsdc,
        uint256 amountToken,
        bool makerGivesUsdc,
        uint64 expiresAt,
        uint16 feeBps
    );
    event OfferFilled(uint256 indexed id, address indexed taker, uint256 feePaid);
    event OfferCancelled(uint256 indexed id);
    event FeeUpdated(uint16 newFeeBps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event PausedSet(bool isPaused);
    event MaxOfferAmountUpdated(address indexed token, uint256 oldCap, uint256 newCap);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier nonReentrant() {
        require(_locked == 1, "reentrancy");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _usdc, address _feeRecipient) {
        require(_usdc != address(0) && _usdc.code.length > 0, "bad usdc");
        require(_feeRecipient != address(0) && _feeRecipient != address(this), "bad fee recipient");
        usdc = _usdc;
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ---------------------------------------------------------------------
    // Create / fill / cancel
    // ---------------------------------------------------------------------

    /// @notice Offer `amountUsdc` USDC for `amountToken` of `token`. Nothing is deposited: approve this
    ///         contract for the USDC first; it stays in your wallet until someone fills.
    function createOfferGivingUsdc(
        address token,
        uint256 amountToken,
        uint256 amountUsdc,
        address taker,
        uint64 expiresAt,
        uint16 maxFeeBps
    ) external nonReentrant returns (uint256 id) {
        _checkNewOffer(token, amountToken, amountUsdc, taker, expiresAt, maxFeeBps);
        _enforceOfferCap(usdc, amountUsdc);
        _enforceOfferCap(token, amountToken);
        _commit(usdc, amountUsdc);
        id = _store(token, amountToken, amountUsdc, taker, expiresAt, true);
        emit OfferCreated(id, msg.sender, taker, token, amountUsdc, amountToken, true, expiresAt, feeBps);
    }

    /// @notice Offer `amountToken` of `token` for `amountUsdc` USDC. Nothing is deposited: approve this
    ///         contract for the token first; it stays in your wallet until someone fills.
    function createOfferGivingToken(
        address token,
        uint256 amountToken,
        uint256 amountUsdc,
        address taker,
        uint64 expiresAt,
        uint16 maxFeeBps
    ) external nonReentrant returns (uint256 id) {
        _checkNewOffer(token, amountToken, amountUsdc, taker, expiresAt, maxFeeBps);
        _enforceOfferCap(token, amountToken);
        _enforceOfferCap(usdc, amountUsdc);
        _commit(token, amountToken);
        id = _store(token, amountToken, amountUsdc, taker, expiresAt, false);
        emit OfferCreated(id, msg.sender, taker, token, amountUsdc, amountToken, false, expiresAt, feeBps);
    }

    /// @notice Fill an open offer: approve the asset the maker wants first. Both sides and the fee move wallet
    ///         to wallet in this transaction, or nothing moves. The fee comes out of the USDC leg.
    function fillOffer(uint256 id) external nonReentrant {
        require(!paused, "paused");
        Offer storage o = offers[id];
        require(o.status == Status.Open, "not open");
        require(o.taker == address(0) || o.taker == msg.sender, "not your offer to fill");
        require(o.maker != msg.sender, "cannot fill own offer");
        require(o.expiresAt == 0 || block.timestamp <= o.expiresAt, "offer expired");

        o.status = Status.Filled;
        _release(o);
        uint256 fee = (o.amountUsdc * o.feeBpsAtCreation) / 10_000;

        if (o.makerGivesUsdc) {
            // Taker's token -> maker, measured at the maker.
            _moveExact(o.token, msg.sender, o.maker, o.amountToken);
            // Maker's USDC -> taker (minus fee) and -> fee recipient.
            _safeTransferFrom(usdc, o.maker, msg.sender, o.amountUsdc - fee);
            if (fee > 0) _safeTransferFrom(usdc, o.maker, feeRecipient, fee);
        } else {
            // Taker's USDC -> maker (minus fee) and -> fee recipient.
            _safeTransferFrom(usdc, msg.sender, o.maker, o.amountUsdc - fee);
            if (fee > 0) _safeTransferFrom(usdc, msg.sender, feeRecipient, fee);
            // Maker's token -> taker, measured at the taker.
            _moveExact(o.token, o.maker, msg.sender, o.amountToken);
        }
        _checkTakerStillBacked(o.makerGivesUsdc ? o.token : usdc);
        emit OfferFilled(id, msg.sender, fee);
    }

    /// @notice Cancel your own open offer (expired or not). Nothing to refund: it never left your wallet.
    function cancelOffer(uint256 id) external {
        Offer storage o = offers[id];
        require(o.status == Status.Open, "not open");
        require(o.maker == msg.sender, "not your offer");
        o.status = Status.Cancelled;
        _release(o);
        emit OfferCancelled(id);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function totalOffers() external view returns (uint256) {
        return nextOfferId - 1;
    }

    function getOffer(uint256 id) external view returns (Offer memory) {
        return offers[id];
    }

    /// @notice Open and not expired (same meaning as v1).
    function isFillable(uint256 id) external view returns (bool) {
        Offer storage o = offers[id];
        return o.status == Status.Open && (o.expiresAt == 0 || block.timestamp <= o.expiresAt);
    }

    /// @notice Fillable right now as far as the maker's side goes: open, not expired, not paused, and the
    ///         maker still has the balance and approval.
    function offerReady(uint256 id) external view returns (bool) {
        Offer storage o = offers[id];
        if (paused || o.status != Status.Open) return false;
        if (o.expiresAt != 0 && block.timestamp > o.expiresAt) return false;
        (address a, uint256 amt) = o.makerGivesUsdc ? (usdc, o.amountUsdc) : (o.token, o.amountToken);
        return IERC20Like(a).balanceOf(o.maker) >= amt && IERC20Like(a).allowance(o.maker, address(this)) >= amt;
    }

    // ---------------------------------------------------------------------
    // Admin (nothing here can move anyone's funds)
    // ---------------------------------------------------------------------

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0) && newRecipient != address(this), "bad recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setPaused(bool newPaused) external onlyOwner {
        paused = newPaused;
        emit PausedSet(newPaused);
    }

    function setMaxOfferAmount(address token, uint256 newCap) external onlyOwner {
        emit MaxOfferAmountUpdated(token, maxOfferAmount[token], newCap);
        maxOfferAmount[token] = newCap;
    }

    /// @notice Two-step ownership transfer: the new owner must call acceptOwnership().
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "bad owner");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _checkNewOffer(
        address token,
        uint256 amountToken,
        uint256 amountUsdc,
        address taker,
        uint64 expiresAt,
        uint16 maxFeeBps
    ) private view {
        require(!paused, "paused");
        require(feeBps <= maxFeeBps, "fee above your max");
        require(token != address(0) && token != usdc, "bad token");
        require(token.code.length > 0, "token has no code");
        require(amountToken > 0, "amountToken = 0");
        require(amountUsdc > 0, "amountUsdc = 0");
        require(taker != msg.sender, "taker is maker");
        require(expiresAt == 0 || expiresAt > block.timestamp, "expiry in the past");
    }

    /// @dev The maker's balance and approval must cover every Open offer of theirs on `asset` plus this one.
    function _commit(address asset, uint256 amount) private {
        uint256 total = committed[msg.sender][asset] + amount;
        require(IERC20Like(asset).balanceOf(msg.sender) >= total, "maker balance too low for all your open offers");
        require(IERC20Like(asset).allowance(msg.sender, address(this)) >= total, "approve enough for all your open offers");
        committed[msg.sender][asset] = total;
    }

    /// @dev After a fill, the taker's own Open offers on the asset they paid with must still be fully backed.
    ///      One approval backs both, so without this a fill could quietly spend the allowance (or balance)
    ///      behind the taker's own offer and leave it stale (Proovant CHORD-02).
    function _checkTakerStillBacked(address paid) private view {
        uint256 mine = committed[msg.sender][paid];
        if (mine == 0) return;
        require(IERC20Like(paid).balanceOf(msg.sender) >= mine, "fill would leave your own open offers short of balance");
        require(IERC20Like(paid).allowance(msg.sender, address(this)) >= mine, "approve this fill on top of your own open offers");
    }

    /// @dev Called once per offer, when it leaves Open (filled or cancelled).
    function _release(Offer storage o) private {
        (address asset, uint256 amt) = o.makerGivesUsdc ? (usdc, o.amountUsdc) : (o.token, o.amountToken);
        committed[o.maker][asset] -= amt;
    }

    function _store(
        address token,
        uint256 amountToken,
        uint256 amountUsdc,
        address taker,
        uint64 expiresAt,
        bool makerGivesUsdc
    ) private returns (uint256 id) {
        id = nextOfferId++;
        offers[id] = Offer({
            maker: msg.sender,
            taker: taker,
            token: token,
            amountUsdc: amountUsdc,
            amountToken: amountToken,
            makerGivesUsdc: makerGivesUsdc,
            status: Status.Open,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            feeBpsAtCreation: feeBps
        });
    }

    function _enforceOfferCap(address asset, uint256 amount) private view {
        uint256 cap = maxOfferAmount[asset];
        require(cap == 0 || amount <= cap, "exceeds per-offer cap");
    }

    /// @dev Moves `amount` of `token` from `from` to `to`; `to` must receive exactly that much.
    function _moveExact(address token, address from, address to, uint256 amount) private {
        uint256 before = IERC20Like(token).balanceOf(to);
        uint256 senderBefore = IERC20Like(token).balanceOf(from);
        _safeTransferFrom(token, from, to, amount);
        require(IERC20Like(token).balanceOf(to) - before == amount, "token took a transfer fee or rebased - unsupported");
        uint256 senderAfter = IERC20Like(token).balanceOf(from);
        require(
            senderAfter <= senderBefore && senderBefore - senderAfter == amount,
            "token took a transfer fee or rebased - unsupported"
        );
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        require(ok && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool)))), "token transferFrom failed");
    }
}
