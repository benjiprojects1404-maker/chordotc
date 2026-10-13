// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * ChordOTC
 * --------
 * Peer-to-peer OTC escrow for ERC-20 token <-> USDC trades on Arc (Circle's L1).
 * Derived from Handshake OTCEscrow v3 (chain 1404), adapted for Arc's USDC-native design.
 *
 * How it works:
 *  - A maker creates an offer, locking EITHER USDC OR an ERC-20 token, and states what they
 *    want back. Optionally restricted to one counterparty (private deal) and/or given an expiry.
 *  - A taker fills the offer by paying the requested asset. Both legs settle in one
 *    transaction or the whole thing reverts.
 *  - The maker can cancel an unfilled offer at any time and get a full refund.
 *  - A protocol fee (basis points, default 0.25%, capped at 3%) is taken from the USDC leg,
 *    snapshotted per offer at creation.
 *
 * Arc-specific design (see docs.arc.io "EVM differences"):
 *  1. USDC is handled ONLY through its 6-decimal ERC-20 interface. Arc's native USDC (gas)
 *     uses 18 decimals and shares the same balance; mixing msg.value with balanceOf gives
 *     amounts 10^12 apart. Nothing in this contract is payable and there is no receive(),
 *     so native value can never enter it.
 *  2. USDC has a blocklist: a transfer to or from a blocklisted address reverts. Payouts to a
 *     party other than the caller (maker proceeds, protocol fee) are attempted directly and,
 *     if the transfer fails, credited instead and claimable later with withdraw(). A
 *     blocklisted maker therefore cannot block a taker's fill, and a blocklisted fee wallet
 *     cannot block trading. Credits are only ever claimable by the credited address itself
 *     (no redirect), so the blocklist is not bypassed.
 *  3. Arc rejects value transfers to address(0). The contract never pays address(0): makers,
 *     takers and the fee recipient are always real addresses (checked where supplied).
 *  4. Arc timestamps are non-decreasing, not strictly increasing, and several blocks can share
 *     one. Expiry is only ever compared with "block.timestamp > expiresAt", which is safe with
 *     repeated timestamps. No ordering logic depends on timestamps.
 *
 * Carried over unchanged in spirit from Handshake v3:
 *  - token.code.length > 0 check at creation (a no-code "token" would let fills succeed
 *    without any real transfer).
 *  - Balance-delta check when pulling tokens in, rejecting fee-on-transfer / rebasing tokens.
 *  - Fee snapshotted per offer; owner can never alter an open offer's terms or touch its funds.
 *  - Per-asset caps, pause for NEW offers only, reentrancy guard on every state change.
 */

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
}

contract ChordOTC {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

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
        bool makerGivesUsdc; // true: maker locked USDC and wants token; false: the reverse
        Status status;
        uint64 createdAt;
        uint64 expiresAt; // 0 = no expiry
        uint16 feeBpsAtCreation;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    address public immutable usdc;

    address public owner;
    address public pendingOwner;
    address public feeRecipient;

    uint16 public feeBps = 25; // 0.25%
    uint16 public constant MAX_FEE_BPS = 300; // 3%

    bool public paused;
    uint256 private _locked = 1;

    /// @notice Optional per-asset cap on the amount locked into one new offer (0 = uncapped).
    mapping(address => uint256) public maxOfferAmount;

    uint256 public nextOfferId = 1;
    mapping(uint256 => Offer) public offers;

    /// @notice Payouts that could not be delivered directly (e.g. a USDC-blocklisted address).
    /// credits[account][asset] — claimable only by `account` via withdraw().
    mapping(address => mapping(address => uint256)) public credits;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event OfferCreated(
        uint256 indexed id,
        address indexed maker,
        address indexed taker,
        address token,
        uint256 amountUsdc,
        uint256 amountToken,
        bool makerGivesUsdc,
        uint64 expiresAt
    );
    event OfferFilled(uint256 indexed id, address indexed taker, uint256 feePaid);
    event OfferCancelled(uint256 indexed id);
    event PayoutCredited(address indexed account, address indexed asset, uint256 amount);
    event CreditWithdrawn(address indexed account, address indexed asset, uint256 amount);
    event FeeUpdated(uint16 newFeeBps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event PausedSet(bool isPaused);
    event MaxOfferAmountUpdated(address indexed token, uint256 oldCap, uint256 newCap);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

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

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    constructor(address _usdc, address _feeRecipient) {
        require(_usdc != address(0) && _usdc.code.length > 0, "bad usdc");
        require(_feeRecipient != address(0), "bad fee recipient");
        usdc = _usdc;
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ---------------------------------------------------------------------
    // Core: create / fill / cancel / withdraw
    // ---------------------------------------------------------------------

    /// @notice Maker locks `amountUsdc` USDC and wants `amountToken` of `token`.
    /// Caller must have approved this contract for `amountUsdc` USDC.
    function createOfferGivingUsdc(
        address token,
        uint256 amountToken,
        uint256 amountUsdc,
        address taker,
        uint64 expiresAt
    ) external nonReentrant returns (uint256 id) {
        _checkNewOffer(token, amountToken, amountUsdc, taker, expiresAt);
        _enforceOfferCap(usdc, amountUsdc);
        id = _store(token, amountToken, amountUsdc, taker, expiresAt, true);
        _pullExact(usdc, msg.sender, amountUsdc);
        emit OfferCreated(id, msg.sender, taker, token, amountUsdc, amountToken, true, expiresAt);
    }

    /// @notice Maker locks `amountToken` of `token` and wants `amountUsdc` USDC.
    /// Caller must have approved this contract for `amountToken` of `token`.
    function createOfferGivingToken(
        address token,
        uint256 amountToken,
        uint256 amountUsdc,
        address taker,
        uint64 expiresAt
    ) external nonReentrant returns (uint256 id) {
        _checkNewOffer(token, amountToken, amountUsdc, taker, expiresAt);
        _enforceOfferCap(token, amountToken);
        id = _store(token, amountToken, amountUsdc, taker, expiresAt, false);
        _pullExact(token, msg.sender, amountToken);
        emit OfferCreated(id, msg.sender, taker, token, amountUsdc, amountToken, false, expiresAt);
    }

    /// @notice Fill an open offer. The taker pays the asset the maker wants (approve it first)
    /// and receives the asset the maker locked. The fee comes out of the USDC leg.
    function fillOffer(uint256 id) external nonReentrant {
        Offer storage o = offers[id];
        require(o.status == Status.Open, "not open");
        require(o.taker == address(0) || o.taker == msg.sender, "not your offer to fill");
        require(o.maker != msg.sender, "cannot fill own offer");
        require(o.expiresAt == 0 || block.timestamp <= o.expiresAt, "offer expired");

        o.status = Status.Filled;

        uint256 fee = (o.amountUsdc * o.feeBpsAtCreation) / 10_000;

        if (o.makerGivesUsdc) {
            // Taker pays token to the escrow, then the maker is paid (or credited).
            _pullExact(o.token, msg.sender, o.amountToken);
            _payOrCredit(o.token, o.maker, o.amountToken);
            // Taker receives the locked USDC minus the fee.
            _safeTransfer(usdc, msg.sender, o.amountUsdc - fee);
        } else {
            // Taker pays USDC to the escrow; maker gets it minus the fee.
            _pullExact(usdc, msg.sender, o.amountUsdc);
            _payOrCredit(usdc, o.maker, o.amountUsdc - fee);
            // Taker receives the locked token.
            _safeTransfer(o.token, msg.sender, o.amountToken);
        }
        if (fee > 0) _payOrCredit(usdc, feeRecipient, fee);

        emit OfferFilled(id, msg.sender, fee);
    }

    /// @notice Cancel your own open offer (expired or not) and get a full refund.
    function cancelOffer(uint256 id) external nonReentrant {
        Offer storage o = offers[id];
        require(o.status == Status.Open, "not open");
        require(o.maker == msg.sender, "not your offer");

        o.status = Status.Cancelled;

        if (o.makerGivesUsdc) {
            _safeTransfer(usdc, msg.sender, o.amountUsdc);
        } else {
            _safeTransfer(o.token, msg.sender, o.amountToken);
        }
        emit OfferCancelled(id);
    }

    /// @notice Claim a payout that could not be delivered directly. Paid only to the caller.
    function withdraw(address asset) external nonReentrant {
        uint256 amount = credits[msg.sender][asset];
        require(amount > 0, "nothing to withdraw");
        credits[msg.sender][asset] = 0;
        _safeTransfer(asset, msg.sender, amount);
        emit CreditWithdrawn(msg.sender, asset, amount);
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

    function isFillable(uint256 id) external view returns (bool) {
        Offer storage o = offers[id];
        return o.status == Status.Open && (o.expiresAt == 0 || block.timestamp <= o.expiresAt);
    }

    // ---------------------------------------------------------------------
    // Admin (cannot touch open offers or credits)
    // ---------------------------------------------------------------------

    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        require(newFeeBps <= MAX_FEE_BPS, "fee too high");
        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "bad recipient");
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedSet(_paused);
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
    // Internal helpers
    // ---------------------------------------------------------------------

    function _checkNewOffer(address token, uint256 amountToken, uint256 amountUsdc, address taker, uint64 expiresAt)
        private
        view
    {
        require(!paused, "offers paused");
        require(token != address(0) && token != usdc, "bad token");
        require(token.code.length > 0, "token has no code");
        require(amountToken > 0, "amountToken = 0");
        require(amountUsdc > 0, "amountUsdc = 0");
        require(taker != msg.sender, "taker is maker");
        require(expiresAt == 0 || expiresAt > block.timestamp, "expiry in the past");
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

    /// @dev Pulls exactly `amount` of `asset` from `from`, rejecting fee-on-transfer/rebasing.
    function _pullExact(address asset, address from, uint256 amount) private {
        uint256 balBefore = IERC20Like(asset).balanceOf(address(this));
        _safeTransferFrom(asset, from, address(this), amount);
        uint256 received = IERC20Like(asset).balanceOf(address(this)) - balBefore;
        require(received == amount, "token took a transfer fee or rebased - unsupported");
    }

    /// @dev Pays `to` directly; if the transfer fails (e.g. USDC blocklist), credits it instead.
    function _payOrCredit(address asset, address to, uint256 amount) private {
        if (amount == 0) return;
        if (!_tryTransfer(asset, to, amount)) {
            credits[to][asset] += amount;
            emit PayoutCredited(to, asset, amount);
        }
    }

    function _tryTransfer(address token, address to, uint256 amount) private returns (bool) {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        return ok && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool))));
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        require(_tryTransfer(token, to, amount), "token transfer failed");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        require(ok && (data.length == 0 || (data.length >= 32 && abi.decode(data, (bool)))), "token transferFrom failed");
    }
}
