// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;


/*
 SavePoint : Earth
 ERC-1155 Avatar Contract (final fix)


 - Pembayaran minting menggunakan token IDRT (ERC-20)
 - Harga mint default: 10_000 (dalam smallest unit IDRT; owner dapat mengubah)
 - Menggunakan OpenZeppelin: ERC1155, Pausable, ReentrancyGuard, SafeERC20
 - Implementasi Ownable sederhana untuk kompatibilitas
 - Implementasi totalSupply/exists untuk menggantikan ERC1155Supply
 - Override _update (sesuai OZ ERC1155 versi terbaru) untuk maintain totalSupply dan block saat paused
*/


import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


contract SavePointAvatar is ERC1155, ReentrancyGuard, Pausable {
   using Counters for Counters.Counter;
   using SafeERC20 for IERC20;


   // --- Simple Ownable implementation ---
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


   // --- Token id tracker and supply tracking (replacement for ERC1155Supply) ---
   Counters.Counter private _tokenIdTracker;
   mapping(uint256 => uint256) private _totalSupply;


   function totalSupply(uint256 id) public view returns (uint256) {
       return _totalSupply[id];
   }


   function exists(uint256 id) public view returns (bool) {
       return _totalSupply[id] > 0 || bytes(_tokenURIs[id]).length > 0;
   }


   // Payment token (IDRT) and price per mint (in IDRT smallest unit)
   IERC20 public paymentToken;
   uint256 public mintPrice;


   // optional: max supply per token id (0 = unlimited)
   mapping(uint256 => uint256) public maxSupplyPerId;


   // per-token metadata URI
   mapping(uint256 => string) private _tokenURIs;


   // events
   event AvatarMinted(address indexed minter, uint256 indexed tokenId, string uri);
   event MintPriceUpdated(uint256 oldPrice, uint256 newPrice);
   event PaymentTokenUpdated(address oldToken, address newToken);


   /**
    * @param _paymentToken address of ERC20 used for payment (IDRT)
    * @param _mintPrice price per single mint (in smallest unit)
    * @param _baseURI base URI for ERC1155 (can be empty)
    */
   constructor(address _paymentToken, uint256 _mintPrice, string memory _baseURI) ERC1155(_baseURI) {
       require(_paymentToken != address(0), "payment token cannot be zero");
       _owner = msg.sender; // set owner
       paymentToken = IERC20(_paymentToken);
       mintPrice = _mintPrice;
   }


   modifier onlyValidToken(uint256 id) {
       require(exists(id), "token does not exist");
       _;
   }


   // ---------- MINTING (public) ----------
   /**
    * @notice Mint a new unique avatar (creates new tokenId and mints 1 copy to msg.sender)
    * @param uri_ metadata URI (should point to JSON metadata on IPFS/Pinata)
    */
   function mintAvatar(string memory uri_) external nonReentrant whenNotPaused {
       require(bytes(uri_).length > 0, "metadata URI required");
       // transfer IDRT from sender to this contract (uses SafeERC20)
       paymentToken.safeTransferFrom(msg.sender, address(this), mintPrice);


       // create new token id (auto-increment)
       _tokenIdTracker.increment();
       uint256 newId = _tokenIdTracker.current();


       // set metadata and mint one copy
       _tokenURIs[newId] = uri_;
       _mint(msg.sender, newId, 1, "");


       emit AvatarMinted(msg.sender, newId, uri_);
   }


   /**
    * @notice Mint multiple copies of an existing avatar token id (if allowed by owner and maxSupply)
    * @param to recipient address
    * @param id token id
    * @param amount number of copies
    */
   function mintExisting(address to, uint256 id, uint256 amount) external nonReentrant whenNotPaused onlyValidToken(id) {
       require(amount > 0, "amount > 0");
       uint256 maxSupply = maxSupplyPerId[id];
       if (maxSupply != 0) {
           require(totalSupply(id) + amount <= maxSupply, "exceeds max supply");
       }
       // collect payment: per-copy price
       uint256 totalCost = mintPrice * amount;
       paymentToken.safeTransferFrom(msg.sender, address(this), totalCost);


       _mint(to, id, amount, "");
   }


   // ---------- VIEW ----------
   /**
    * Override ERC1155.uri to return per-token URI when set
    */
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
       uint256 old = mintPrice;
       mintPrice = newPrice;
       emit MintPriceUpdated(old, newPrice);
   }


   function setPaymentToken(address newPaymentToken) external onlyOwner {
       require(newPaymentToken != address(0), "zero address");
       address old = address(paymentToken);
       paymentToken = IERC20(newPaymentToken);
       emit PaymentTokenUpdated(old, newPaymentToken);
   }


   function setMaxSupplyForId(uint256 id, uint256 maxSupply) external onlyOwner onlyValidToken(id) {
       require(maxSupply == 0 || maxSupply >= totalSupply(id), "invalid max supply");
       maxSupplyPerId[id] = maxSupply;
   }


   function setTokenURI(uint256 id, string memory newUri) external onlyOwner onlyValidToken(id) {
       _tokenURIs[id] = newUri;
   }


   // pause and unpause contract (uses Pausable)
   function pause() external onlyOwner {
       _pause();
   }
   function unpause() external onlyOwner {
       _unpause();
   }


   // withdraw collected IDRT to owner
   function withdrawPaymentToken(address to, uint256 amount) external onlyOwner nonReentrant {
       require(to != address(0), "invalid to");
       paymentToken.safeTransfer(to, amount);
   }


   // emergency rescue of any ERC20 tokens mistakenly sent
   function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner {
       require(to != address(0), "invalid to");
       IERC20(tokenAddr).safeTransfer(to, amount);
   }


   // ---------- OVERRIDES / HOOKS ----------
   /**
    * OpenZeppelin ERC1155 (recent versions) use internal hook _update(from,to,ids,values).
    * Override it to maintain totalSupply and block transfers when paused.
    */
   function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
       internal
       virtual
       override
   {
       // block while paused
       require(!paused(), "token transfer while paused");


       // call parent logic first
       super._update(from, to, ids, values);


       // update supply mapping similar to ERC1155Supply
       if (from == address(0)) {
           for (uint256 i = 0; i < ids.length; ++i) {
               _totalSupply[ids[i]] += values[i];
           }
       }


       if (to == address(0)) {
           for (uint256 i = 0; i < ids.length; ++i) {
               uint256 id = ids[i];
               uint256 amount = values[i];
               require(_totalSupply[id] >= amount, "burn amount exceeds supply");
               _totalSupply[id] -= amount;
           }
       }
   }


   // allow owner to set base URI if needed
   function setBaseURI(string memory newUri) external onlyOwner {
       _setURI(newUri);
   }


}