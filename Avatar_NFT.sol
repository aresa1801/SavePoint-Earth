// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SavePointAvatar is ERC1155, Pausable, ReentrancyGuard {
    using Counters for Counters.Counter;
    using SafeERC20 for IERC20;

    // --- Ownable ---
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == _owner, "Ownable: caller is not the owner");
        _;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is zero");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    // --- Token ID tracker & supply tracking ---
    Counters.Counter private _tokenIdTracker;
    mapping(uint256 => uint256) private _totalSupply;

    function totalSupply(uint256 id) public view returns (uint256) {
        return _totalSupply[id];
    }

    // Per-token metadata URI
    mapping(uint256 => string) private _tokenURIs;

    function exists(uint256 id) public view returns (bool) {
        return _totalSupply[id] > 0 || bytes(_tokenURIs[id]).length > 0;
    }

    // Payment token (IDRT) and fee collector address
    IERC20 public paymentToken;
    address public feeCollector;

    // Mint price default 15,000 IDRT (smallest unit)
    uint256 public mintPrice = 15000;

    // Optional max supply per token id (0 = unlimited)
    mapping(uint256 => uint256) public maxSupplyPerId;

    // Events
    event AvatarMinted(address indexed minter, uint256 indexed tokenId, string uri);
    event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event PaymentTokenUpdated(address indexed oldToken, address indexed newToken);
    event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);
    event MaxSupplySet(uint256 indexed id, uint256 maxSupply);
    event TokenURISet(uint256 indexed id, string uri);

    /**
     * @param _initialOwner owner address
     * @param _paymentToken address of ERC20 used for payment (IDRT)
     * @param _feeCollector address receiving mint fees
     * @param _baseURI base URI for ERC1155 metadata
     */
    constructor(
        address _initialOwner,
        address _paymentToken,
        address _feeCollector,
        string memory _baseURI
    ) ERC1155(_baseURI) {
        require(_initialOwner != address(0), "owner zero");
        require(_paymentToken != address(0), "payment token zero");
        require(_feeCollector != address(0), "fee collector zero");

        _owner = _initialOwner;
        paymentToken = IERC20(_paymentToken);
        feeCollector = _feeCollector;
    }

    modifier onlyValidToken(uint256 id) {
        require(exists(id), "token does not exist");
        _;
    }

    // ---------- MINTING ----------

    /// @notice Mint a new unique avatar with new tokenId
    /// @param uri_ metadata URI (should point to JSON metadata on IPFS or similar)
    function mintAvatar(string memory uri_) external nonReentrant whenNotPaused {
        require(bytes(uri_).length > 0, "metadata URI required");

        // transfer payment directly to feeCollector
        paymentToken.safeTransferFrom(msg.sender, feeCollector, mintPrice);

        // increment tokenId
        _tokenIdTracker.increment();
        uint256 newId = _tokenIdTracker.current();

        // set metadata URI
        _tokenURIs[newId] = uri_;

        // mint 1 token to sender
        _mint(msg.sender, newId, 1, "");
        _totalSupply[newId] = 1;

        emit AvatarMinted(msg.sender, newId, uri_);
        emit TokenURISet(newId, uri_);
    }

    /// @notice Mint multiple copies of an existing avatar token id
    /// @param to recipient address
    /// @param id token id to mint
    /// @param amount number of copies
    function mintExisting(address to, uint256 id, uint256 amount) external nonReentrant whenNotPaused onlyValidToken(id) {
        require(amount > 0, "amount > 0");

        uint256 maxSupply = maxSupplyPerId[id];
        if (maxSupply != 0) {
            require(totalSupply(id) + amount <= maxSupply, "exceeds max supply");
        }

        uint256 totalCost = mintPrice * amount;
        paymentToken.safeTransferFrom(msg.sender, feeCollector, totalCost);

        _mint(to, id, amount, "");
        _totalSupply[id] += amount;
    }

    // ---------- URI override ----------

    function uri(uint256 id) public view virtual override returns (string memory) {
        require(exists(id), "URI query for nonexistent token");
        string memory tokenUri = _tokenURIs[id];
        if (bytes(tokenUri).length > 0) {
            return tokenUri;
        }
        return super.uri(id);
    }

    // ---------- OWNER / ADMIN ----------

    function setMintPrice(uint256 newPrice) external onlyOwner {
        uint256 oldPrice = mintPrice;
        mintPrice = newPrice;
        emit MintPriceUpdated(oldPrice, newPrice);
    }

    function setPaymentToken(address newPaymentToken) external onlyOwner {
        require(newPaymentToken != address(0), "zero address");
        address old = address(paymentToken);
        paymentToken = IERC20(newPaymentToken);
        emit PaymentTokenUpdated(old, newPaymentToken);
    }

    function setFeeCollector(address newCollector) external onlyOwner {
        require(newCollector != address(0), "zero address");
        address old = feeCollector;
        feeCollector = newCollector;
        emit FeeCollectorUpdated(old, newCollector);
    }

    function setMaxSupplyForId(uint256 id, uint256 maxSupply) external onlyOwner onlyValidToken(id) {
        require(maxSupply == 0 || maxSupply >= totalSupply(id), "invalid max supply");
        maxSupplyPerId[id] = maxSupply;
        emit MaxSupplySet(id, maxSupply);
    }

    function setTokenURI(uint256 id, string calldata newUri) external onlyOwner onlyValidToken(id) {
        _tokenURIs[id] = newUri;
        emit TokenURISet(id, newUri);
    }

    function setBaseURI(string calldata newUri) external onlyOwner {
        _setURI(newUri);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // Emergency rescue for any ERC20 tokens sent mistakenly
    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "invalid address");
        IERC20(tokenAddr).safeTransfer(to, amount);
    }

    // ---------- OVERRIDES / HOOKS ----------

    /// @dev Override _update to maintain totalSupply and block transfer when paused
    function _update(address from, address to, uint256[] memory ids, uint256[] memory amounts) internal virtual override {
        require(!paused(), "token transfer while paused");

        super._update(from, to, ids, amounts);

        if (from == address(0)) {
            for (uint256 i = 0; i < ids.length; i++) {
                _totalSupply[ids[i]] += amounts[i];
            }
        }

        if (to == address(0)) {
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 id = ids[i];
                uint256 amount = amounts[i];
                require(_totalSupply[id] >= amount, "burn exceeds supply");
                _totalSupply[id] -= amount;
            }
        }
    }
}
