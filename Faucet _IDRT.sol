// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract IDRTFaucet is Ownable2Step, ReentrancyGuard, Pausable {
    IERC20 public immutable idrtToken;

    uint256 public constant CLAIM_AMOUNT = 100_000 * 10**18; // 100 ribu IDRT
    uint256 public constant CLAIM_COOLDOWN = 1 days;

    mapping(address => uint256) private _lastClaimTime;
    uint256 private _totalDistributed;

    // =============== EVENTS ===============
    event TokensClaimed(address indexed recipient, uint256 amount);
    event TokensWithdrawn(address indexed owner, uint256 amount);
    event FaucetFunded(address indexed funder, uint256 amount);
    event EmergencyStop(bool isPaused);

    constructor(address _idrtToken) Ownable(msg.sender) {
        require(_idrtToken != address(0), "Invalid token address");
        idrtToken = IERC20(_idrtToken);
    }

    // =============== USER FUNCTION ===============
    function claimTokens() external nonReentrant whenNotPaused {
        require(canClaim(msg.sender), "Claim cooldown active");
        require(availableBalance() >= CLAIM_AMOUNT, "Insufficient faucet balance");

        _lastClaimTime[msg.sender] = block.timestamp;
        _totalDistributed += CLAIM_AMOUNT;

        bool success = idrtToken.transfer(msg.sender, CLAIM_AMOUNT);
        require(success, "Token transfer failed");

        emit TokensClaimed(msg.sender, CLAIM_AMOUNT);
    }

    function fundFaucet(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be > 0");

        bool success = idrtToken.transferFrom(msg.sender, address(this), amount);
        require(success, "Funding failed");

        emit FaucetFunded(msg.sender, amount);
    }

    // =============== VIEW FUNCTIONS ===============
    function canClaim(address _user) public view returns (bool) {
        return block.timestamp >= _lastClaimTime[_user] + CLAIM_COOLDOWN;
    }

    function nextClaimTime(address _user) public view returns (uint256) {
        if (_lastClaimTime[_user] == 0) return 0;
        return _lastClaimTime[_user] + CLAIM_COOLDOWN;
    }

    function availableBalance() public view returns (uint256) {
        return idrtToken.balanceOf(address(this));
    }

    function totalDistributed() public view returns (uint256) {
        return _totalDistributed;
    }

    function lastClaimTime(address _user) public view returns (uint256) {
        return _lastClaimTime[_user];
    }

    // =============== ADMIN FUNCTIONS ===============
    function withdrawTokens(uint256 _amount) external onlyOwner {
        require(_amount <= availableBalance(), "Amount exceeds balance");

        bool success = idrtToken.transfer(owner(), _amount);
        require(success, "Withdrawal failed");

        emit TokensWithdrawn(owner(), _amount);
    }

    function togglePause() external onlyOwner {
        if (paused()) {
            _unpause();
        } else {
            _pause();
        }
        emit EmergencyStop(paused());
    }

    // =============== OVERRIDES ===============
    function renounceOwnership() public pure override {
        revert("Cannot renounce ownership");
    }
}
