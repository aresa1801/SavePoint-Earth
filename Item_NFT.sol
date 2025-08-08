// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
* @title SavePointItems (ERC-1155)
* @notice ERC-1155 contract to mint Item Boosts and Resource Packs for SavePoint: Earth
* @dev Owner-controlled minting, per-token metadata, optional maxSupply, one-time claim, pause, burn,
*      and optional public minting that charges a mint fee in IDRT (or any ERC20 paymentToken).
*/

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SavePointItems is ERC1155, Ownable, Pausable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    Counters.Counter private _typeCounter;

    /// @notice Total supply tracking per token id
    mapping(uint256 => uint256) private _totalSupply;
    /// @notice Optional max supply per token id (0 = unlimited)
    mapping(uint256 => uint256) public maxSupply;
    /// @notice Per-token metadata URI (overrides base URI if set)
    mapping(uint256 => string) private _tokenURI;

    /// @notice Claim supply left for one-time claims (each account can claim once)
    mapping(uint256 => uint256) public claimSupplyLeft;
    /// @notice Tracks whether an address already claimed a specific token id
    mapping(address => mapping(uint256 => bool)) public hasClaimed;

    // Payment token (e.g., IDRT) used for public minting fees
    IERC20 public paymentToken;
    // Fee collector address that receives mint fees
    address public feeCollector;
    // Mint fee per single unit (in paymentToken smallest unit). Default 5000.
    uint256 public mintFee;

    /* Events */
    event ItemTypeCreated(uint256 indexed id, uint256 maxSupply, string uri);
    event ItemMinted(address indexed to, uint256 indexed id, uint256 amount);
    event ItemBatchMinted(address indexed to, uint256[] ids, uint256[] amounts);
    event ItemBurned(address indexed from, uint256 indexed id, uint256 amount);
    event ClaimSupplySet(uint256 indexed id, uint256 supply);
    event ItemClaimed(address indexed claimer, uint256 indexed id);
    event TokenURISet(uint256 indexed id, string uri);
    event MaxSupplySet(uint256 indexed id, uint256 maxSupplyValue);
    event PaymentTokenUpdated(address indexed oldToken, address indexed newToken);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event MintFeeUpdated(uint256 oldFee, uint256 newFee);

    constructor(address initialOwner, string memory baseURI, address _paymentToken, address _feeCollector)
        ERC1155(baseURI)
        Ownable(initialOwner)
    {
        require(initialOwner != address(0), "owner zero");
        require(_paymentToken != address(0), "payment token zero");
        require(_feeCollector != address(0), "fee collector zero");

        paymentToken = IERC20(_paymentToken);
        feeCollector = _feeCollector;
        mintFee = 5000;

        // start type ids at 1
        _typeCounter.increment();
    }

    // -------------------- Item Type Management --------------------

    function createItemType(uint256 _maxSupply, string calldata uri_) external onlyOwner returns (uint256 newId) {
        require(bytes(uri_).length > 0, "uri required");

        _typeCounter.increment();
        newId = _typeCounter.current();

        maxSupply[newId] = _maxSupply;
        _tokenURI[newId] = uri_;

        emit ItemTypeCreated(newId, _maxSupply, uri_);
        emit TokenURISet(newId, uri_);
    }

    function setMaxSupply(uint256 id, uint256 _max) external onlyOwner {
        require(id > 0 && bytes(_tokenURI[id]).length > 0, "invalid id");
        maxSupply[id] = _max;
        emit MaxSupplySet(id, _max);
    }

    function setTokenURI(uint256 id, string calldata uri_) external onlyOwner {
        require(id > 0, "invalid id");
        _tokenURI[id] = uri_;
        emit TokenURISet(id, uri_);
    }

    function setBaseURI(string calldata newuri) external onlyOwner {
        _setURI(newuri);
    }

    // -------------------- Minting (Owner) --------------------

    function mint(address to, uint256 id, uint256 amount) external onlyOwner whenNotPaused nonReentrant {
        require(to != address(0), "to zero");
        require(amount > 0, "amount zero");
        require(bytes(_tokenURI[id]).length > 0, "token type not exist");

        uint256 max = maxSupply[id];
        if (max != 0) {
            require(_totalSupply[id] + amount <= max, "exceeds max");
        }

        _mint(to, id, amount, "");
        _totalSupply[id] += amount;
        emit ItemMinted(to, id, amount);
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external onlyOwner whenNotPaused nonReentrant {
        require(to != address(0), "to zero");
        require(ids.length == amounts.length, "len mismatch");

        for (uint256 i = 0; i < ids.length; i++) {
            require(bytes(_tokenURI[ids[i]]).length > 0, "token type not exist");
            uint256 max = maxSupply[ids[i]];
            if (max != 0) {
                require(_totalSupply[ids[i]] + amounts[i] <= max, "exceeds max");
            }
            _totalSupply[ids[i]] += amounts[i];
        }

        _mintBatch(to, ids, amounts, "");
        emit ItemBatchMinted(to, ids, amounts);
    }

    function mintAirdrop(address[] calldata recipients, uint256 id, uint256 amountEach) external onlyOwner whenNotPaused nonReentrant {
        require(recipients.length > 0, "no recipients");
        require(bytes(_tokenURI[id]).length > 0, "token type not exist");
        require(amountEach > 0, "amount zero");

        uint256 total = recipients.length * amountEach;
        uint256 max = maxSupply[id];
        if (max != 0) {
            require(_totalSupply[id] + total <= max, "exceeds max");
        }

        for (uint256 i = 0; i < recipients.length; i++) {
            _mint(recipients[i], id, amountEach, "");
            _totalSupply[id] += amountEach;
            emit ItemMinted(recipients[i], id, amountEach);
        }
    }

    // -------------------- Public Minting (fee-based) --------------------

    function publicMint(uint256 id, uint256 amount) external whenNotPaused nonReentrant {
        require(amount > 0, "amount zero");
        require(bytes(_tokenURI[id]).length > 0, "token type not exist");

        uint256 max = maxSupply[id];
        if (max != 0) {
            require(_totalSupply[id] + amount <= max, "exceeds max");
        }

        uint256 totalCost = mintFee * amount;
        paymentToken.safeTransferFrom(msg.sender, feeCollector, totalCost);

        _mint(msg.sender, id, amount, "");
        _totalSupply[id] += amount;
        emit ItemMinted(msg.sender, id, amount);
    }

    function publicMintBatch(uint256[] calldata ids, uint256[] calldata amounts) external whenNotPaused nonReentrant {
        require(ids.length == amounts.length, "len mismatch");

        uint256 totalUnits = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            require(bytes(_tokenURI[ids[i]]).length > 0, "token type not exist");
            uint256 max = maxSupply[ids[i]];
            if (max != 0) {
                require(_totalSupply[ids[i]] + amounts[i] <= max, "exceeds max");
            }
            totalUnits += amounts[i];
        }
        uint256 totalCost = mintFee * totalUnits;
        paymentToken.safeTransferFrom(msg.sender, feeCollector, totalCost);

        _mintBatch(msg.sender, ids, amounts, "");
        for (uint256 i = 0; i < ids.length; i++) _totalSupply[ids[i]] += amounts[i];
        emit ItemBatchMinted(msg.sender, ids, amounts);
    }

    // -------------------- Claiming --------------------

    function setClaimSupply(uint256 id, uint256 supply) external onlyOwner {
        require(bytes(_tokenURI[id]).length > 0, "token type not exist");
        claimSupplyLeft[id] = supply;
        emit ClaimSupplySet(id, supply);
    }

    function claim(uint256 id) external whenNotPaused nonReentrant {
        require(claimSupplyLeft[id] > 0, "no claim supply");
        require(!hasClaimed[msg.sender][id], "already claimed");
        require(bytes(_tokenURI[id]).length > 0, "token type not exist");

        uint256 max = maxSupply[id];
        if (max != 0) {
            require(_totalSupply[id] + 1 <= max, "exceeds max");
        }

        claimSupplyLeft[id] -= 1;
        hasClaimed[msg.sender][id] = true;

        _mint(msg.sender, id, 1, "");
        _totalSupply[id] += 1;

        emit ItemClaimed(msg.sender, id);
    }

    // -------------------- Burning --------------------

    function burn(address account, uint256 id, uint256 value) external whenNotPaused {
        require(account == msg.sender || isApprovedForAll(account, msg.sender), "not owner nor approved");
        _burn(account, id, value);
        require(_totalSupply[id] >= value, "burn exceeds supply");
        _totalSupply[id] -= value;
        emit ItemBurned(account, id, value);
    }

    function burnBatch(address account, uint256[] calldata ids, uint256[] calldata values) external whenNotPaused {
        require(account == msg.sender || isApprovedForAll(account, msg.sender), "not owner nor approved");
        _burnBatch(account, ids, values);
        for (uint256 i = 0; i < ids.length; i++) {
            require(_totalSupply[ids[i]] >= values[i], "burn exceeds supply");
            _totalSupply[ids[i]] -= values[i];
            emit ItemBurned(account, ids[i], values[i]);
        }
    }

    // -------------------- Views --------------------

    function uri(uint256 id) public view virtual override returns (string memory) {
        if (bytes(_tokenURI[id]).length > 0) return _tokenURI[id];
        return super.uri(id);
    }

    function totalSupply(uint256 id) external view returns (uint256) {
        return _totalSupply[id];
    }

    function exists(uint256 id) external view returns (bool) {
        return _totalSupply[id] > 0 || bytes(_tokenURI[id]).length > 0;
    }

    // -------------------- Admin --------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // -------------------- Hooks --------------------

    // Parameter names omitted to avoid compiler warnings about unused variables
    function _beforeTokenTransfer(
        address /*operator*/,
        address /*from*/,
        address /*to*/,
        uint256[] memory /*ids*/,
        uint256[] memory /*amounts*/,
        bytes memory /*data*/
    ) internal virtual {
        require(!paused(), "paused");
        // No super call to avoid override issues
    }

    // -------------------- Payment & Fee Admin --------------------

    function setPaymentToken(address newToken) external onlyOwner {
        require(newToken != address(0), "zero token");
        address old = address(paymentToken);
        paymentToken = IERC20(newToken);
        emit PaymentTokenUpdated(old, newToken);
    }

    function setFeeCollector(address newCollector) external onlyOwner {
        require(newCollector != address(0), "zero collector");
        address old = feeCollector;
        feeCollector = newCollector;
        emit FeeCollectorUpdated(old, newCollector);
    }

    function setMintFee(uint256 newFee) external onlyOwner {
        uint256 old = mintFee;
        mintFee = newFee;
        emit MintFeeUpdated(old, newFee);
    }
}
