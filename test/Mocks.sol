// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// Minimal ERC-20 with an optional Circle-style blocklist and an optional transfer fee,
/// used only for tests.
contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;
    uint256 public feeBps; // transfer fee for fee-on-transfer tests

    constructor(string memory _n, string memory _s, uint8 _d) { name = _n; symbol = _s; decimals = _d; }

    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function setBlocked(address a, bool b) external { blocked[a] = b; }
    function setFeeBps(uint256 f) external { feeBps = f; }

    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }

    function transfer(address to, uint256 a) external returns (bool) { _move(msg.sender, to, a); return true; }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        require(allowance[f][msg.sender] >= a, "allowance");
        allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        require(!blocked[f] && !blocked[to] && !blocked[msg.sender], "Blacklistable: account is blacklisted");
        require(to != address(0), "zero");
        require(balanceOf[f] >= a, "balance");
        uint256 fee = a * feeBps / 10_000;
        balanceOf[f] -= a;
        balanceOf[to] += a - fee;
        totalSupply -= fee;
    }
}
