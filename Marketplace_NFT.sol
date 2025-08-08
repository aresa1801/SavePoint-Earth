// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SavePointMarketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public paymentToken;      // e.g. IDRT
    address public feeCollector;     // wallet untuk fee
    uint256 public feePercent;       // fee % dalam basis poin (1000 = 10%)
    
    // Allowed NFT contract addresses yang bisa dijual
    mapping(address => bool) public allowedNFTContracts;

    // Listing struct untuk jual NFT
    struct Listing {
        address seller;
        address nftContract;
        uint256 tokenId;
        uint256 amount;   // untuk ERC1155
        uint256 price;    // harga total dalam paymentToken smallest unit
        bool isERC1155;   // tipe NFT
        bool active;
    }

    // listingId auto increment
    uint256 private _listingIdCounter;

    // listingId => Listing
    mapping(uint256 => Listing) public listings;

    // Events
    event NFTListed(uint256 indexed listingId, address indexed seller, address indexed nftContract, uint256 tokenId, uint256 amount, uint256 price, bool isERC1155);
    event NFTSale(uint256 indexed listingId, address indexed buyer, uint256 price, uint256 fee);
    event NFTDelisted(uint256 indexed listingId);

    constructor(address initialOwner, address _paymentToken, address _feeCollector, uint256 _feePercent) 
        Ownable(initialOwner) 
    {
        require(initialOwner != address(0), "owner zero");
        require(_paymentToken != address(0), "paymentToken zero");
        require(_feeCollector != address(0), "feeCollector zero");
        require(_feePercent <= 10000, "feePercent max 10000");

        paymentToken = IERC20(_paymentToken);
        feeCollector = _feeCollector;
        feePercent = _feePercent; // contoh: 1000 = 10%
        _listingIdCounter = 1; // start dari 1
    }

    // Owner functions
    function setPaymentToken(address _paymentToken) external onlyOwner {
        require(_paymentToken != address(0), "zero addr");
        paymentToken = IERC20(_paymentToken);
    }

    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "zero addr");
        feeCollector = _feeCollector;
    }

    function setFeePercent(uint256 _feePercent) external onlyOwner {
        require(_feePercent <= 10000, "max 10000");
        feePercent = _feePercent;
    }

    function setAllowedNFTContract(address nftContract, bool allowed) external onlyOwner {
        allowedNFTContracts[nftContract] = allowed;
    }

    // List NFT for sale
    function listNFT(address nftContract, uint256 tokenId, uint256 amount, uint256 price, bool isERC1155) external nonReentrant {
        require(allowedNFTContracts[nftContract], "NFT contract not allowed");
        require(price > 0, "price zero");

        if (isERC1155) {
            require(amount > 0, "amount zero");
            // check ownership and approval
            IERC1155 erc1155 = IERC1155(nftContract);
            require(erc1155.balanceOf(msg.sender, tokenId) >= amount, "insufficient balance");
            require(erc1155.isApprovedForAll(msg.sender, address(this)), "not approved");
        } else {
            require(amount == 1, "amount must be 1 for ERC721");
            IERC721 erc721 = IERC721(nftContract);
            require(erc721.ownerOf(tokenId) == msg.sender, "not owner");
            require(erc721.isApprovedForAll(msg.sender, address(this)) || erc721.getApproved(tokenId) == address(this), "not approved");
        }

        uint256 listingId = _listingIdCounter++;
        listings[listingId] = Listing({
            seller: msg.sender,
            nftContract: nftContract,
            tokenId: tokenId,
            amount: amount,
            price: price,
            isERC1155: isERC1155,
            active: true
        });

        emit NFTListed(listingId, msg.sender, nftContract, tokenId, amount, price, isERC1155);
    }

    // Cancel listing
    function delistNFT(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active, "listing inactive");
        require(l.seller == msg.sender, "not seller");

        l.active = false;

        emit NFTDelisted(listingId);
    }

    // Buy NFT from marketplace
    function buyNFT(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        require(l.active, "listing inactive");

        uint256 price = l.price;
        uint256 fee = (price * feePercent) / 10000;
        uint256 sellerAmount = price - fee;

        // Transfer payment token from buyer to seller and feeCollector
        paymentToken.safeTransferFrom(msg.sender, l.seller, sellerAmount);
        paymentToken.safeTransferFrom(msg.sender, feeCollector, fee);

        // Transfer NFT from seller to buyer
        if (l.isERC1155) {
            IERC1155(l.nftContract).safeTransferFrom(l.seller, msg.sender, l.tokenId, l.amount, "");
        } else {
            IERC721(l.nftContract).safeTransferFrom(l.seller, msg.sender, l.tokenId);
        }

        l.active = false;

        emit NFTSale(listingId, msg.sender, price, fee);
    }

    // View helper to check if NFT contract allowed
    function isAllowedNFT(address nftContract) external view returns (bool) {
        return allowedNFTContracts[nftContract];
    }
}
