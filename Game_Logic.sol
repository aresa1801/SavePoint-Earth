// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

contract SavePointGameLogic is Ownable, Pausable, ReentrancyGuard {
    IERC721 public avatarNFT;
    IERC1155 public itemNFT;

    address public treasuryWallet;
    address public rewardSigner;

    mapping(address => uint256) public userLevel;
    mapping(address => mapping(uint256 => uint256)) public questProgress;
    mapping(address => mapping(uint256 => bool)) public rewardClaimed;

    event LevelUpdated(address indexed user, uint256 newLevel);
    event QuestProgressUpdated(address indexed user, uint256 questId, uint256 progress);
    event RewardClaimed(address indexed user, uint256 rewardId);

    constructor(
        address initialOwner,
        address _avatarNFT,
        address _itemNFT,
        address _treasuryWallet,
        address _rewardSigner
    ) Ownable(initialOwner) {
        require(_avatarNFT != address(0), "avatarNFT zero");
        require(_itemNFT != address(0), "itemNFT zero");
        require(_treasuryWallet != address(0), "treasury zero");
        require(_rewardSigner != address(0), "signer zero");

        avatarNFT = IERC721(_avatarNFT);
        itemNFT = IERC1155(_itemNFT);
        treasuryWallet = _treasuryWallet;
        rewardSigner = _rewardSigner;
    }

    function setAvatarNFT(address _avatarNFT) external onlyOwner {
        require(_avatarNFT != address(0), "zero addr");
        avatarNFT = IERC721(_avatarNFT);
    }

    function setItemNFT(address _itemNFT) external onlyOwner {
        require(_itemNFT != address(0), "zero addr");
        itemNFT = IERC1155(_itemNFT);
    }

    function setTreasuryWallet(address _wallet) external onlyOwner {
        require(_wallet != address(0), "zero addr");
        treasuryWallet = _wallet;
    }

    function setRewardSigner(address _signer) external onlyOwner {
        require(_signer != address(0), "zero addr");
        rewardSigner = _signer;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function updateLevel(address user, uint256 newLevel) external onlyOwner {
        require(user != address(0), "zero user");
        userLevel[user] = newLevel;
        emit LevelUpdated(user, newLevel);
    }

    function updateQuestProgress(address user, uint256 questId, uint256 progress) external onlyOwner {
        require(user != address(0), "zero user");
        questProgress[user][questId] = progress;
        emit QuestProgressUpdated(user, questId, progress);
    }

    /// @notice Internal function to recreate EIP-191 prefixed message hash
    function toEthSignedMessageHash(bytes32 hash) internal pure returns (bytes32) {
        // 32 is length of hash in bytes
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));
    }

    function claimReward(
        uint256 rewardId,
        uint256 amount,
        bytes calldata signature
    ) external whenNotPaused nonReentrant {
        require(!rewardClaimed[msg.sender][rewardId], "already claimed");

        bytes32 messageHash = keccak256(abi.encodePacked(msg.sender, rewardId, amount));
        bytes32 ethSignedMessageHash = toEthSignedMessageHash(messageHash);

        address recoveredSigner = ECDSA.recover(ethSignedMessageHash, signature);
        require(recoveredSigner == rewardSigner, "invalid signature");

        rewardClaimed[msg.sender][rewardId] = true;

        // Add reward logic here, e.g. mint or transfer tokens/items

        emit RewardClaimed(msg.sender, rewardId);
    }
}
