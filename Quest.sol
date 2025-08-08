// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title QuestManager (Upgradeable - UUPS)
 * @notice Upgradeable QuestManager using OpenZeppelin UUPS pattern.
 *         - Auto generates quests 1..200 (can be modified by owner)
 *         - Selectable reward options per quest (OffchainPoints, ERC20, ERC1155, StatBoost)
 *         - Players can start, complete, and claim a chosen reward per quest
 *         - Admin can add reward options, fund ERC20/ERC1155 rewards to contract
 *         - Uses OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable
 */

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/IERC1155Upgradeable.sol";

contract QuestManagerUpgradeable is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    enum RewardType { OffchainPoints, ERC20, ERC1155, StatBoost }

    struct RewardOption {
        RewardType rtype;
        uint256 value;
        address token; // for ERC20
        address erc1155Contract;
        uint256 erc1155TokenId;
        uint256 erc1155Amount;
        string label;
    }

    struct Quest {
        uint256 id;
        string name;
        uint256 difficulty;
        bool exists;
    }

    struct PlayerQuest {
        bool started;
        bool completed;
        bool rewardClaimed;
        uint256 chosenRewardIndex;
    }

    // state
    mapping(uint256 => Quest) public quests;
    uint256 public totalQuests;
    mapping(uint256 => RewardOption[]) private questRewards;
    mapping(address => mapping(uint256 => PlayerQuest)) public playerProgress;
    mapping(address => mapping(string => uint256)) public playerStats;

    // events
    event QuestCreated(uint256 indexed questId, string name, uint256 difficulty);
    event RewardOptionAdded(uint256 indexed questId, uint256 indexed optionIndex, RewardType rtype, string label);
    event QuestStarted(address indexed player, uint256 indexed questId);
    event QuestCompleted(address indexed player, uint256 indexed questId);
    event RewardClaimed(address indexed player, uint256 indexed questId, uint256 indexed optionIndex, RewardType rtype);
    event OffchainPointsAwarded(address indexed player, uint256 questId, uint256 points);
    event ERC20RewardSent(address indexed token, address indexed to, uint256 amount);
    event ERC1155RewardSent(address indexed contractAddr, address indexed to, uint256 tokenId, uint256 amount);
    event StatBoostApplied(address indexed player, string statKey, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize function (replace constructor). Owner will be msg.sender.
     */
    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        // generate default 200 quests
        uint256 count = 200;
        for (uint256 i = 1; i <= count; i++) {
            string memory name = _buildQuestName(i);
            uint256 difficulty = i;
            quests[i] = Quest({ id: i, name: name, difficulty: difficulty, exists: true });
            emit QuestCreated(i, name, difficulty);

            uint256 defaultPoints = i * 10; // scale
            questRewards[i].push(RewardOption({
                rtype: RewardType.OffchainPoints,
                value: defaultPoints,
                token: address(0),
                erc1155Contract: address(0),
                erc1155TokenId: 0,
                erc1155Amount: 0,
                label: "Default points"
            }));
            emit RewardOptionAdded(i, 0, RewardType.OffchainPoints, "Default points");
        }
        totalQuests = count;
    }

    // ------------------------- Player functions -------------------------

    function startQuest(uint256 questId) external whenNotPaused {
        require(_questExists(questId), "Quest does not exist");
        PlayerQuest storage pq = playerProgress[msg.sender][questId];
        require(!pq.started, "Already started");
        require(!pq.rewardClaimed, "Already claimed");

        pq.started = true;
        emit QuestStarted(msg.sender, questId);
    }

    function completeQuest(uint256 questId) external whenNotPaused {
        require(_questExists(questId), "Quest does not exist");
        PlayerQuest storage pq = playerProgress[msg.sender][questId];
        require(pq.started, "Quest not started");
        require(!pq.completed, "Already completed");
        require(!pq.rewardClaimed, "Already claimed");

        pq.completed = true;
        emit QuestCompleted(msg.sender, questId);
    }

    function claimReward(uint256 questId, uint256 optionIndex) external nonReentrant whenNotPaused {
        require(_questExists(questId), "Quest does not exist");
        PlayerQuest storage pq = playerProgress[msg.sender][questId];
        require(pq.started, "Quest not started");
        require(pq.completed, "Quest not completed");
        require(!pq.rewardClaimed, "Reward already claimed");
        require(optionIndex < questRewards[questId].length, "Invalid reward option");

        RewardOption memory opt = questRewards[questId][optionIndex];

        // mark claimed first
        pq.rewardClaimed = true;
        pq.chosenRewardIndex = optionIndex;

        if (opt.rtype == RewardType.OffchainPoints) {
            playerStats[msg.sender]["offchain_points"] += opt.value;
            emit OffchainPointsAwarded(msg.sender, questId, opt.value);
        } else if (opt.rtype == RewardType.StatBoost) {
            playerStats[msg.sender]["boost"] += opt.value;
            emit StatBoostApplied(msg.sender, "boost", opt.value);
        } else if (opt.rtype == RewardType.ERC20) {
            require(opt.token != address(0), "ERC20 token not set");
            IERC20Upgradeable(opt.token).safeTransfer(msg.sender, opt.value);
            emit ERC20RewardSent(opt.token, msg.sender, opt.value);
        } else if (opt.rtype == RewardType.ERC1155) {
            require(opt.erc1155Contract != address(0), "ERC1155 contract not set");
            require(opt.erc1155Amount > 0, "ERC1155 amount zero");
            IERC1155Upgradeable(opt.erc1155Contract).safeTransferFrom(address(this), msg.sender, opt.erc1155TokenId, opt.erc1155Amount, "");
            emit ERC1155RewardSent(opt.erc1155Contract, msg.sender, opt.erc1155TokenId, opt.erc1155Amount);
        }

        emit RewardClaimed(msg.sender, questId, optionIndex, opt.rtype);
    }

    // ------------------------- Admin functions -------------------------

    function addRewardOption(
        uint256 questId,
        RewardType rtype,
        uint256 value,
        address token,
        address erc1155Contract,
        uint256 erc1155TokenId,
        uint256 erc1155Amount,
        string calldata label
    ) external onlyOwner whenNotPaused {
        require(_questExists(questId), "Quest does not exist");
        if (rtype == RewardType.ERC20) {
            require(token != address(0), "ERC20 address required");
            require(value > 0, "ERC20 value required");
        } else if (rtype == RewardType.ERC1155) {
            require(erc1155Contract != address(0), "ERC1155 contract required");
            require(erc1155Amount > 0, "ERC1155 amount required");
        } else {
            require(value > 0, "value required");
        }

        questRewards[questId].push(RewardOption({
            rtype: rtype,
            value: value,
            token: token,
            erc1155Contract: erc1155Contract,
            erc1155TokenId: erc1155TokenId,
            erc1155Amount: erc1155Amount,
            label: label
        }));

        uint256 idx = questRewards[questId].length - 1;
        emit RewardOptionAdded(questId, idx, rtype, label);
    }

    function setQuest(uint256 questId, string calldata name, uint256 difficulty) external onlyOwner whenNotPaused {
        require(questId > 0, "Invalid questId");
        quests[questId] = Quest({ id: questId, name: name, difficulty: difficulty, exists: true });
        if (questId > totalQuests) totalQuests = questId;
        emit QuestCreated(questId, name, difficulty);
    }

    function clearRewardOptions(uint256 questId) external onlyOwner {
        require(_questExists(questId), "Quest does not exist");
        delete questRewards[questId];
    }

    // ------------------------- Views -------------------------

    function getRewardOptionsCount(uint256 questId) external view returns (uint256) {
        return questRewards[questId].length;
    }

    function getRewardOption(uint256 questId, uint256 index) external view returns (RewardOption memory) {
        require(index < questRewards[questId].length, "Index out of bounds");
        return questRewards[questId][index];
    }

    function getAllRewardOptions(uint256 questId) external view returns (RewardOption[] memory) {
        return questRewards[questId];
    }

    // ------------------------- Funding & Rescue -------------------------

    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "invalid to");
        IERC20Upgradeable(tokenAddr).safeTransfer(to, amount);
    }

    function rescueERC1155(address contractAddr, address to, uint256 tokenId, uint256 amount) external onlyOwner {
        require(to != address(0), "invalid to");
        IERC1155Upgradeable(contractAddr).safeTransferFrom(address(this), to, tokenId, amount, "");
    }

    // ------------------------- ERC1155 Receiver hooks -------------------------

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    // ------------------------- Admin controls -------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ------------------------- Internal helpers -------------------------

    function _questExists(uint256 questId) internal view returns (bool) {
        return quests[questId].exists;
    }

    function _buildQuestName(uint256 idx) internal pure returns (string memory) {
        return string(abi.encodePacked("Quest Level ", _uintToString(idx)));
    }

    function _uintToString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 temp = v;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (v != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(v % 10)));
            v /= 10;
        }
        return string(buffer);
    }

    // Authorize upgrades (onlyOwner)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
