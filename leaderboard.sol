// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LeaderboardUpgradeable (Patched)
 * @dev Upgradeable leaderboard contract (UUPS) to store and expose top players.
 * Improvements applied to address security and gas concerns:
 * - Use O(1) index mapping `topIndex` to avoid linear search when checking membership
 * - Limit `maxEntries` to a safer upper bound (200) to avoid DoS via gas exhaustion
 * - Avoid clearing large mappings in loops; resetSeason only clears topPlayers and indexes
 * - Add input validations and more events for better observability
 * - Keep upgradeable UUPS pattern and authorized updater guard
 */

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract LeaderboardUpgradeable is Initializable, OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    struct Entry {
        address player;
        uint256 score;
    }

    // mapping to store raw scores
    mapping(address => uint256) public scores;

    // sorted top players (descending by score)
    Entry[] private topPlayers;
    uint256 public maxEntries; // max number of entries kept in leaderboard (e.g., 100)

    // fast lookup: topIndex[player] = index+1 in topPlayers array; 0 means not present
    mapping(address => uint256) public topIndex;

    // authorized updaters (e.g., QuestManager contract, Arena contract)
    mapping(address => bool) public authorizedUpdaters;

    // events
    event ScoreUpdated(address indexed updater, address indexed player, uint256 newScore);
    event AuthorizedUpdaterChanged(address indexed updater, bool allowed);
    event MaxEntriesChanged(uint256 oldMax, uint256 newMax);
    event SeasonReset();
    event PlayerRemovedFromTop(address indexed player);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev initialize the contract
     * @param _maxEntries maximum leaderboard entries to keep (capped at 200)
     */
    function initialize(uint256 _maxEntries) public initializer {
        require(_maxEntries > 0 && _maxEntries <= 200, "invalid max entries, max 200");
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        maxEntries = _maxEntries;
    }

    modifier onlyAuthorized() {
        require(authorizedUpdaters[msg.sender] || owner() == msg.sender, "not authorized");
        _;
    }

    /**
     * @notice Authorize or revoke an updater (game contract)
     * @param updater address to authorize/revoke
     * @param allowed true to authorize, false to revoke
     */
    function setAuthorizedUpdater(address updater, bool allowed) external onlyOwner {
        require(updater != address(0), "invalid updater");
        authorizedUpdaters[updater] = allowed;
        emit AuthorizedUpdaterChanged(updater, allowed);
    }

    /**
     * @notice Update player's score. Can be called by authorized updaters only.
     * @param player player's address
     * @param newScore new score to set (replaces previous). If you want incremental, call with sum externally.
     */
    function updateScore(address player, uint256 newScore) external whenNotPaused onlyAuthorized nonReentrant {
        require(player != address(0), "invalid player");

        scores[player] = newScore;
        _insertOrUpdateTop(player, newScore);

        emit ScoreUpdated(msg.sender, player, newScore);
    }

    /**
     * @dev internal: insert or update topPlayers array maintaining descending order by score
     * Uses topIndex mapping to avoid O(N) membership checks.
     */
    function _insertOrUpdateTop(address player, uint256 newScore) internal {
        uint256 idxPlusOne = topIndex[player];
        if (idxPlusOne != 0) {
            // existing entry
            uint256 idx = idxPlusOne - 1;
            topPlayers[idx].score = newScore;
            _bubbleUp(idx);
            _bubbleDown(idx);
        } else {
            // not present
            if (topPlayers.length < maxEntries) {
                topPlayers.push(Entry({ player: player, score: newScore }));
                uint256 newIdx = topPlayers.length - 1;
                topIndex[player] = newIdx + 1;
                _bubbleUp(newIdx);
            } else {
                // full: check if newScore is greater than smallest
                uint256 lastIndex = topPlayers.length - 1;
                if (newScore <= topPlayers[lastIndex].score) {
                    return; // no change
                }
                // remove mapping for removed player
                address removed = topPlayers[lastIndex].player;
                topIndex[removed] = 0;
                // replace last with new entry
                topPlayers[lastIndex] = Entry({ player: player, score: newScore });
                topIndex[player] = lastIndex + 1;
                _bubbleUp(lastIndex);
            }
        }
    }

    function _bubbleUp(uint256 idx) internal {
        while (idx > 0) {
            uint256 prev = idx - 1;
            if (topPlayers[prev].score >= topPlayers[idx].score) break;
            // swap and update indices
            Entry memory tmp = topPlayers[prev];
            topPlayers[prev] = topPlayers[idx];
            topPlayers[idx] = tmp;
            topIndex[topPlayers[prev].player] = prev + 1;
            topIndex[topPlayers[idx].player] = idx + 1;
            idx = prev;
        }
    }

    function _bubbleDown(uint256 idx) internal {
        uint256 len = topPlayers.length;
        while (idx + 1 < len) {
            uint256 next = idx + 1;
            if (topPlayers[idx].score >= topPlayers[next].score) break;
            Entry memory tmp = topPlayers[next];
            topPlayers[next] = topPlayers[idx];
            topPlayers[idx] = tmp;
            topIndex[topPlayers[next].player] = next + 1;
            topIndex[topPlayers[idx].player] = idx + 1;
            idx = next;
        }
    }

    /**
     * @notice Get top N players (N capped by maxEntries)
     * @param n number of top players to return
     */
    function getTopPlayers(uint256 n) external view returns (Entry[] memory) {
        if (n > topPlayers.length) n = topPlayers.length;
        Entry[] memory out = new Entry[](n);
        for (uint256 i = 0; i < n; i++) out[i] = topPlayers[i];
        return out;
    }

    /**
     * @notice Get rank and score of a player. Rank is 1-based. Returns (rank, score). If not in top list, rank = 0.
     */
    function getPlayerRank(address player) external view returns (uint256 rank, uint256 scoreOut) {
        scoreOut = scores[player];
        uint256 idxPlusOne = topIndex[player];
        if (idxPlusOne == 0) return (0, scoreOut);
        return (idxPlusOne, scoreOut);
    }

    /**
     * @notice Adjust maximum leaderboard size (owner only)
     */
    function setMaxEntries(uint256 newMax) external onlyOwner {
        require(newMax > 0 && newMax <= 200, "invalid max entries");
        uint256 old = maxEntries;
        if (newMax < maxEntries) {
            // truncate from back and clear topIndex for removed players
            while (topPlayers.length > newMax) {
                Entry memory removed = topPlayers[topPlayers.length - 1];
                topIndex[removed.player] = 0;
                topPlayers.pop();
                emit PlayerRemovedFromTop(removed.player);
            }
        }
        maxEntries = newMax;
        emit MaxEntriesChanged(old, newMax);
    }

    /**
     * @notice Reset leaderboard (season reset) — only clears top list and indices to avoid iterating over massive score map
     */
    function resetSeason() external onlyOwner {
        // clear indices (cheap loop bounded by maxEntries)
        for (uint256 i = 0; i < topPlayers.length; i++) {
            topIndex[topPlayers[i].player] = 0;
        }
        delete topPlayers;
        emit SeasonReset();
    }

    // Authorize upgrades (only owner)
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
