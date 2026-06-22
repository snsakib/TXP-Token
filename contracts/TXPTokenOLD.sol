// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title  Triple X POS Token (TXP)
 * @author iYap Global
 * @notice Native utility token of the iYap Global ecosystem.
 *         Powers merchant processing, payments, transfers, and exchange
 *         across all iYap services.
 *
 * @dev    ERC-20 compliant implementation with:
 *           - Fixed total supply of 1,000,000,000 TXP minted to deployer.
 *           - Owner-controlled pause   : halt all transfers in an emergency.
 *           - Owner-controlled blacklist: block specific addresses from transacting.
 *           - User-initiated burn      : permanently reduce circulating supply.
 *           - Safe ownership transfer / renounce pattern.
 *           - increaseAllowance / decreaseAllowance helpers (no front-run risk).
 */
contract TXPToken {
    // ─── Token Metadata ──────────────────────────────────────────────────────

    string public constant name     = "Triple X POS Token";
    string public constant symbol   = "TXP";
    uint8  public constant decimals = 18;

    /// @notice Hard-capped supply – no additional minting is ever possible.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(decimals);

    // ─── State ───────────────────────────────────────────────────────────────

    address public owner;
    bool    public paused;

    uint256 private _totalSupply;

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool)                        private _blacklisted;

    // ─── Events ──────────────────────────────────────────────────────────────

    /// @dev ERC-20 required events.
    event Transfer(address indexed from,  address indexed to,      uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /// @dev Governance & operational events.
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event Blacklisted(address indexed account);
    event RemovedFromBlacklist(address indexed account);
    event Burn(address indexed burner, uint256 value);

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOwner() {
        require(msg.sender == owner, "TXP: caller is not the owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "TXP: token transfers are paused");
        _;
    }

    modifier notBlacklisted(address account) {
        require(!_blacklisted[account], "TXP: address is blacklisted");
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────────────────

    /**
     * @notice Deploys the TXP token and mints the entire fixed supply to
     *         the deployer address, which becomes the initial contract owner.
     */
    constructor() {
        owner        = msg.sender;
        _totalSupply = TOTAL_SUPPLY;
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ─── ERC-20 View Functions ───────────────────────────────────────────────

    /// @notice Returns the total token supply currently in circulation.
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice Returns the TXP balance held by `account`.
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice Returns the remaining number of tokens that `spender` is
    ///         allowed to transfer on behalf of `_owner`.
    function allowance(address _owner, address spender)
        external
        view
        returns (uint256)
    {
        return _allowances[_owner][spender];
    }

    // ─── ERC-20 Write Functions ───────────────────────────────────────────────

    /**
     * @notice Moves `amount` TXP from the caller to `to`.
     * @dev    Reverts if paused or either address is blacklisted.
     */
    function transfer(address to, uint256 amount)
        external
        whenNotPaused
        notBlacklisted(msg.sender)
        notBlacklisted(to)
        returns (bool)
    {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @notice Sets `amount` as the allowance of `spender` over the caller's tokens.
     * @dev    Prefer increaseAllowance / decreaseAllowance to avoid race conditions.
     */
    function approve(address spender, uint256 amount)
        external
        notBlacklisted(msg.sender)
        returns (bool)
    {
        _approve(msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Moves `amount` TXP from `from` to `to` using the caller's allowance.
     * @dev    Deducts from the caller's allowance. Reverts if paused or any
     *         involved address is blacklisted.
     */
    function transferFrom(address from, address to, uint256 amount)
        external
        whenNotPaused
        notBlacklisted(from)
        notBlacklisted(to)
        notBlacklisted(msg.sender)
        returns (bool)
    {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= amount, "TXP: transfer amount exceeds allowance");
        unchecked {
            _allowances[from][msg.sender] = currentAllowance - amount;
        }
        emit Approval(from, msg.sender, _allowances[from][msg.sender]);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @notice Atomically increases the allowance granted to `spender`.
     * @dev    Safer alternative to a plain `approve` call.
     */
    function increaseAllowance(address spender, uint256 addedValue)
        external
        notBlacklisted(msg.sender)
        returns (bool)
    {
        _approve(msg.sender, spender, _allowances[msg.sender][spender] + addedValue);
        return true;
    }

    /**
     * @notice Atomically decreases the allowance granted to `spender`.
     * @dev    Reverts if the result would fall below zero.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue)
        external
        notBlacklisted(msg.sender)
        returns (bool)
    {
        uint256 current = _allowances[msg.sender][spender];
        require(current >= subtractedValue, "TXP: decreased allowance below zero");
        unchecked {
            _approve(msg.sender, spender, current - subtractedValue);
        }
        return true;
    }

    // ─── Burn ────────────────────────────────────────────────────────────────

    /**
     * @notice Destroys `amount` TXP from the caller's balance, permanently
     *         reducing the total supply.
     * @dev    Emits both a {Burn} and a {Transfer} to address(0) event.
     */
    function burn(uint256 amount)
        external
        whenNotPaused
        notBlacklisted(msg.sender)
    {
        require(_balances[msg.sender] >= amount, "TXP: burn amount exceeds balance");
        unchecked {
            _balances[msg.sender] -= amount;
            _totalSupply          -= amount;
        }
        emit Burn(msg.sender, amount);
        emit Transfer(msg.sender, address(0), amount);
    }

    // ─── Owner: Pause / Unpause ───────────────────────────────────────────────

    /// @notice Pauses all token transfers. Only callable by the owner.
    function pause() external onlyOwner {
        require(!paused, "TXP: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpauses token transfers. Only callable by the owner.
    function unpause() external onlyOwner {
        require(paused, "TXP: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ─── Owner: Blacklist ─────────────────────────────────────────────────────

    /**
     * @notice Blacklists `account`, preventing it from sending or receiving TXP.
     * @dev    The contract owner cannot be blacklisted.
     */
    function blacklist(address account) external onlyOwner {
        require(account != owner, "TXP: cannot blacklist the owner");
        require(!_blacklisted[account], "TXP: address already blacklisted");
        _blacklisted[account] = true;
        emit Blacklisted(account);
    }

    /// @notice Removes `account` from the blacklist.
    function removeFromBlacklist(address account) external onlyOwner {
        require(_blacklisted[account], "TXP: address is not blacklisted");
        _blacklisted[account] = false;
        emit RemovedFromBlacklist(account);
    }

    /// @notice Returns `true` if `account` is currently blacklisted.
    function isBlacklisted(address account) external view returns (bool) {
        return _blacklisted[account];
    }

    // ─── Owner: Ownership Management ─────────────────────────────────────────

    /**
     * @notice Transfers contract ownership to `newOwner`.
     * @dev    `newOwner` must not be the zero address.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "TXP: new owner is the zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /**
     * @notice Renounces ownership, leaving the contract without an owner.
     * @dev    WARNING: This is irreversible. Pause/blacklist controls will be
     *         permanently disabled. Use with extreme caution.
     */
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // ─── Internal Helpers ────────────────────────────────────────────────────

    function _transfer(address from, address to, uint256 amount) internal {
        require(from != address(0), "TXP: transfer from the zero address");
        require(to   != address(0), "TXP: transfer to the zero address");
        require(_balances[from] >= amount, "TXP: transfer amount exceeds balance");
        unchecked {
            _balances[from] -= amount;
            _balances[to]   += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address _owner, address spender, uint256 amount) internal {
        require(_owner  != address(0), "TXP: approve from the zero address");
        require(spender != address(0), "TXP: approve to the zero address");
        _allowances[_owner][spender] = amount;
        emit Approval(_owner, spender, amount);
    }
}
