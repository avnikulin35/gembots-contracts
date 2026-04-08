// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title GemBotsGenesisVault
 * @notice Wrapper contract that adds Genesis-only privileges on top of the live GemBotsNFAv5 collection.
 * @dev The original NFT contract remains untouched. This wrapper only reads ownerOf(tokenId)
 *      from the deployed collection and maintains independent accounting for fee distribution,
 *      governance helpers, and optional Genesis staking.
 */
contract GemBotsGenesisVault is Ownable, ReentrancyGuard {
    uint256 public constant GENESIS_SUPPLY = 100;
    uint256 public constant GENESIS_WEIGHT = 10;
    uint256 public constant DIAMOND_WEIGHT = 1;

    uint256 private constant SHARE_PRECISION = 1e18;
    uint256 private constant ACC_REWARD_PRECISION = 1e36;

    IERC721 public immutable gemBotsNfa;

    /// @notice Accumulated ETH rewards per share, scaled by ACC_REWARD_PRECISION.
    uint256 public accRewardPerShare;

    /// @notice Sum of all active Genesis shares. Base case = 100 * SHARE_PRECISION.
    uint256 public totalShares = GENESIS_SUPPLY * SHARE_PRECISION;

    /// @notice ETH sent before accounting was live or when owner rescues/adjusts pending funds.
    uint256 public unallocatedRewards;

    /// @notice Extra share boost for staked Genesis tokens, in basis points above the 1.0x base.
    /// Example: 2000 = 20% share boost.
    uint256 public stakeBoostBps = 2_000;

    mapping(uint256 => bool) public isStaked;
    mapping(uint256 => address) public stakerOf;
    mapping(uint256 => uint256) public rewardDebt;

    event RevenueDeposited(address indexed from, uint256 amount, uint256 distributedAmount);
    event Claimed(address indexed account, uint256 indexed tokenId, uint256 amount);
    event ClaimedBatch(address indexed account, uint256 amount, uint256 tokenCount);
    event Staked(address indexed account, uint256 indexed tokenId, uint256 shares);
    event Unstaked(address indexed account, uint256 indexed tokenId, uint256 shares);
    event StakeBoostUpdated(uint256 oldBoostBps, uint256 newBoostBps);
    event RescueETH(address indexed to, uint256 amount);

    error NotGenesisToken();
    error NotTokenOwner();
    error AlreadyStaked();
    error NotStaked();
    error NoRewards();
    error InvalidBoost();
    error ZeroAddress();
    error TransferFailed();

    constructor(address gemBotsNfaAddress, address initialOwner) {
        if (gemBotsNfaAddress == address(0) || initialOwner == address(0)) revert ZeroAddress();
        gemBotsNfa = IERC721(gemBotsNfaAddress);
        _transferOwnership(initialOwner);
    }

    receive() external payable {
        _depositRevenue(msg.value);
    }

    /// @notice Explicit platform fee deposit entrypoint.
    function depositRevenue() external payable {
        _depositRevenue(msg.value);
    }

    /// @notice Immutable Genesis definition: token IDs 1..100 are Genesis forever.
    function isGenesis(uint256 tokenId) public pure returns (bool) {
        return tokenId >= 1 && tokenId <= GENESIS_SUPPLY;
    }

    /// @notice External helper for privilege checks. Genesis implies auto-Diamond.
    function isGenesisDiamond(uint256 tokenId) external pure returns (bool) {
        return isGenesis(tokenId);
    }

    /// @notice Governance weight helper for voting systems built on top of the collection.
    function getVotingWeight(uint256 tokenId) external pure returns (uint256) {
        return isGenesis(tokenId) ? GENESIS_WEIGHT : DIAMOND_WEIGHT;
    }

    /// @notice Stake a Genesis NFA to receive boosted revenue-share allocation.
    function stake(uint256 tokenId) external nonReentrant {
        if (!isGenesis(tokenId)) revert NotGenesisToken();
        if (gemBotsNfa.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (isStaked[tokenId]) revert AlreadyStaked();

        uint256 shares = _sharesForToken(tokenId, true);
        isStaked[tokenId] = true;
        stakerOf[tokenId] = msg.sender;
        totalShares += (shares - _baseShares());
        rewardDebt[tokenId] = (shares * accRewardPerShare) / ACC_REWARD_PRECISION;

        emit Staked(msg.sender, tokenId, shares);
    }

    /// @notice Unstake a Genesis NFA. Pending rewards are claimed first.
    function unstake(uint256 tokenId) external nonReentrant {
        if (!isGenesis(tokenId)) revert NotGenesisToken();
        if (!isStaked[tokenId]) revert NotStaked();
        if (stakerOf[tokenId] != msg.sender) revert NotTokenOwner();
        if (gemBotsNfa.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();

        _claimSingle(tokenId, msg.sender);

        uint256 shares = _sharesForToken(tokenId, true);
        totalShares -= (shares - _baseShares());
        isStaked[tokenId] = false;
        stakerOf[tokenId] = address(0);
        rewardDebt[tokenId] = 0;

        emit Unstaked(msg.sender, tokenId, shares);
    }

    /// @notice Claim accumulated revenue share for a single Genesis token.
    function claim(uint256 tokenId) external nonReentrant returns (uint256 amount) {
        if (!isGenesis(tokenId)) revert NotGenesisToken();
        if (gemBotsNfa.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        amount = _claimSingle(tokenId, msg.sender);
        if (amount == 0) revert NoRewards();
    }

    /// @notice Claim for multiple Genesis tokens owned by the caller.
    function claimBatch(uint256[] calldata tokenIds) external nonReentrant returns (uint256 totalAmount) {
        uint256 length = tokenIds.length;
        for (uint256 i = 0; i < length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (!isGenesis(tokenId)) revert NotGenesisToken();
            if (gemBotsNfa.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
            totalAmount += _claimSingle(tokenId, msg.sender);
        }
        if (totalAmount == 0) revert NoRewards();
        emit ClaimedBatch(msg.sender, totalAmount, length);
    }

    /// @notice View the claimable ETH amount for a Genesis token.
    function pendingRewards(uint256 tokenId) public view returns (uint256) {
        if (!isGenesis(tokenId)) return 0;
        uint256 shares = _currentShares(tokenId);
        uint256 accumulated = (shares * accRewardPerShare) / ACC_REWARD_PRECISION;
        uint256 debt = rewardDebt[tokenId];
        return accumulated > debt ? accumulated - debt : 0;
    }

    /// @notice View the current revenue-share weight for a token.
    function sharesOf(uint256 tokenId) external view returns (uint256) {
        if (!isGenesis(tokenId)) return 0;
        return _currentShares(tokenId);
    }

    /// @notice Owner can tune the staking boost for future reward accrual.
    /// @dev Existing stakers should unstake/re-stake if integrators want debts normalized under a new boost.
    function setStakeBoostBps(uint256 newBoostBps) external onlyOwner {
        if (newBoostBps > 10_000) revert InvalidBoost();
        uint256 oldBoostBps = stakeBoostBps;
        stakeBoostBps = newBoostBps;
        emit StakeBoostUpdated(oldBoostBps, newBoostBps);
    }

    /// @notice Rescue ETH that was intentionally kept outside reward accounting.
    function rescueUnallocatedETH(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount > unallocatedRewards) revert NoRewards();
        unallocatedRewards -= amount;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit RescueETH(to, amount);
    }

    function _depositRevenue(uint256 amount) internal {
        if (amount == 0) revert NoRewards();
        if (totalShares == 0) {
            unallocatedRewards += amount;
            emit RevenueDeposited(msg.sender, amount, 0);
            return;
        }

        uint256 distributable = amount + unallocatedRewards;
        unallocatedRewards = 0;
        accRewardPerShare += (distributable * ACC_REWARD_PRECISION) / totalShares;

        emit RevenueDeposited(msg.sender, amount, distributable);
    }

    function _claimSingle(uint256 tokenId, address to) internal returns (uint256 amount) {
        amount = pendingRewards(tokenId);
        uint256 shares = _currentShares(tokenId);
        rewardDebt[tokenId] = (shares * accRewardPerShare) / ACC_REWARD_PRECISION;

        if (amount > 0) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) revert TransferFailed();
            emit Claimed(to, tokenId, amount);
        }
    }

    function _currentShares(uint256 tokenId) internal view returns (uint256) {
        return _sharesForToken(tokenId, isStaked[tokenId]);
    }

    function _sharesForToken(uint256, bool staked) internal view returns (uint256) {
        uint256 base = _baseShares();
        if (!staked) return base;
        return base + ((base * stakeBoostBps) / 10_000);
    }

    function _baseShares() internal pure returns (uint256) {
        return SHARE_PRECISION;
    }
}
