// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GemBotsBetting
 * @notice AI vs AI betting arena on BSC. Users bet BNB on bot fights.
 * @dev Migrated from Solana/Anchor. No delegatecall. Checks-effects-interactions throughout.
 */
contract GemBotsBetting is ReentrancyGuard {
    // ──────────────────────────────────────────────
    //  Enums
    // ──────────────────────────────────────────────
    enum PoolStatus { Open, Locked, Resolved, Cancelled }
    enum Side { A, B }

    // ──────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────
    struct Pool {
        address authority;
        string matchId;
        string botAName;
        string botBName;
        uint256 poolA;
        uint256 poolB;
        uint32 totalBets;
        PoolStatus status;
        Side winner;
        bool hasWinner;
        uint16 feeBps;
        uint256 createdAt;
        uint256 resolvedAt;
        bool feesCollected;
        bool exists;
    }

    struct Bet {
        Side side;
        uint256 amount;
        bool claimed;
        uint256 payout;
        uint256 timestamp;
        bool exists;
    }

    // ──────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────
    uint16 public constant MAX_FEE_BPS = 2000;   // 20 %
    uint256 public constant MIN_BET = 0.001 ether; // 0.001 BNB
    uint256 public constant MAX_BET = 10 ether;    // 10 BNB

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────
    address public owner;
    address public treasury;
    uint16 public defaultFeeBps;          // default fee for new pools (bps)
    bool public initialized;

    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => mapping(address => Bet)) public bets;

    // track all pool IDs for enumeration
    bytes32[] public poolIds;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────
    event Initialized(address indexed owner, address indexed treasury, uint16 feeBps);
    event PoolCreated(bytes32 indexed poolId, string matchId, string botAName, string botBName, uint16 feeBps);
    event BetPlaced(bytes32 indexed poolId, address indexed bettor, Side side, uint256 amount);
    event PoolLocked(bytes32 indexed poolId);
    event PoolResolved(bytes32 indexed poolId, Side winner, uint256 poolA, uint256 poolB);
    event Claimed(bytes32 indexed poolId, address indexed bettor, uint256 payout);
    event RefundClaimed(bytes32 indexed poolId, address indexed bettor, uint256 amount);
    event PoolCancelled(bytes32 indexed poolId);
    event FeesCollected(bytes32 indexed poolId, address indexed treasury, uint256 amount);
    event ConfigUpdated(address indexed newOwner, address indexed newTreasury, uint16 newFeeBps);

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────
    modifier onlyOwner() {
        require(msg.sender == owner, "GemBots: not owner");
        _;
    }

    modifier onlyInitialized() {
        require(initialized, "GemBots: not initialized");
        _;
    }

    // ──────────────────────────────────────────────
    //  Initialize
    // ──────────────────────────────────────────────
    /**
     * @notice One-time initialization. Sets owner, treasury, default fee.
     * @param _treasury  Address that receives betting fees.
     * @param _feeBps    Default fee in basis points (500 = 5%).
     */
    function initialize(address _treasury, uint16 _feeBps) external {
        require(!initialized, "GemBots: already initialized");
        require(_treasury != address(0), "GemBots: zero treasury");
        require(_feeBps <= MAX_FEE_BPS, "GemBots: fee too high");

        owner = msg.sender;
        treasury = _treasury;
        defaultFeeBps = _feeBps;
        initialized = true;

        emit Initialized(msg.sender, _treasury, _feeBps);
    }

    // ──────────────────────────────────────────────
    //  Pool management
    // ──────────────────────────────────────────────
    /**
     * @notice Create a new betting pool for a match.
     * @param _matchId      Unique match identifier string.
     * @param _botAName     Name of bot A.
     * @param _botBName     Name of bot B.
     * @param _customFeeBps Fee override for this pool (0 = use default).
     */
    function createPool(
        string calldata _matchId,
        string calldata _botAName,
        string calldata _botBName,
        uint16 _customFeeBps
    ) external onlyOwner onlyInitialized {
        require(bytes(_matchId).length > 0, "GemBots: empty matchId");
        require(bytes(_botAName).length > 0, "GemBots: empty botAName");
        require(bytes(_botBName).length > 0, "GemBots: empty botBName");

        uint16 fee = _customFeeBps > 0 ? _customFeeBps : defaultFeeBps;
        require(fee <= MAX_FEE_BPS, "GemBots: fee too high");

        bytes32 poolId = keccak256(abi.encodePacked(_matchId));
        require(!pools[poolId].exists, "GemBots: pool already exists");

        Pool storage p = pools[poolId];
        p.authority = msg.sender;
        p.matchId = _matchId;
        p.botAName = _botAName;
        p.botBName = _botBName;
        p.status = PoolStatus.Open;
        p.feeBps = fee;
        p.createdAt = block.timestamp;
        p.exists = true;

        poolIds.push(poolId);

        emit PoolCreated(poolId, _matchId, _botAName, _botBName, fee);
    }

    /**
     * @notice Lock pool — no more bets accepted.
     */
    function lockPool(bytes32 _poolId) external onlyOwner onlyInitialized {
        Pool storage p = pools[_poolId];
        require(p.exists, "GemBots: pool not found");
        require(p.status == PoolStatus.Open, "GemBots: pool not open");

        p.status = PoolStatus.Locked;

        emit PoolLocked(_poolId);
    }

    /**
     * @notice Resolve pool — declare winner.
     */
    function resolve(bytes32 _poolId, Side _winner) external onlyOwner onlyInitialized {
        Pool storage p = pools[_poolId];
        require(p.exists, "GemBots: pool not found");
        require(
            p.status == PoolStatus.Open || p.status == PoolStatus.Locked,
            "GemBots: cannot resolve"
        );

        p.status = PoolStatus.Resolved;
        p.winner = _winner;
        p.hasWinner = true;
        p.resolvedAt = block.timestamp;

        emit PoolResolved(_poolId, _winner, p.poolA, p.poolB);
    }

    /**
     * @notice Cancel pool — enable refunds.
     */
    function cancel(bytes32 _poolId) external onlyOwner onlyInitialized {
        Pool storage p = pools[_poolId];
        require(p.exists, "GemBots: pool not found");
        require(
            p.status == PoolStatus.Open || p.status == PoolStatus.Locked,
            "GemBots: cannot cancel"
        );

        p.status = PoolStatus.Cancelled;

        emit PoolCancelled(_poolId);
    }

    // ──────────────────────────────────────────────
    //  Betting
    // ──────────────────────────────────────────────
    /**
     * @notice Place a bet on side A or B. Send BNB with the call.
     * @param _poolId  Pool to bet on.
     * @param _side    Side.A or Side.B.
     */
    function placeBet(bytes32 _poolId, Side _side) external payable onlyInitialized {
        require(msg.value >= MIN_BET, "GemBots: below min bet");
        require(msg.value <= MAX_BET, "GemBots: above max bet");

        Pool storage p = pools[_poolId];
        require(p.exists, "GemBots: pool not found");
        require(p.status == PoolStatus.Open, "GemBots: pool not open");

        Bet storage b = bets[_poolId][msg.sender];
        require(!b.exists, "GemBots: already bet");

        // Effects
        b.side = _side;
        b.amount = msg.value;
        b.timestamp = block.timestamp;
        b.exists = true;

        if (_side == Side.A) {
            p.poolA += msg.value;
        } else {
            p.poolB += msg.value;
        }
        p.totalBets += 1;

        emit BetPlaced(_poolId, msg.sender, _side, msg.value);
    }

    // ──────────────────────────────────────────────
    //  Claims & refunds
    // ──────────────────────────────────────────────
    /**
     * @notice Winner claims payout after pool resolution.
     *         payout = (betAmount / winningPool) * totalPool * (1 - feeBps/10000)
     */
    function claim(bytes32 _poolId) external nonReentrant onlyInitialized {
        Pool storage p = pools[_poolId];
        require(p.exists, "GemBots: pool not found");
        require(p.status == PoolStatus.Resolved, "GemBots: not resolved");
        require(p.hasWinner, "GemBots: no winner set");

        Bet storage b = bets[_poolId][msg.sender];
        require(b.exists, "GemBots: no bet found");
        require(!b.claimed, "GemBots: already claimed");
        require(b.side == p.winner, "GemBots: not a winner");

        uint256 winningPool = p.winner == Side.A ? p.poolA : p.poolB;
        uint256 totalPool = p.poolA + p.poolB;

        // payout = (betAmount * totalPool * (10000 - feeBps)) / (winningPool * 10000)
        uint256 payout = (b.amount * totalPool * (10000 - uint256(p.feeBps))) /
                         (winningPool * 10000);

        // Effects before interaction
        b.claimed = true;
        b.payout = payout;

        // Interaction
        (bool success, ) = payable(msg.sender).call{value: payout}("");
        require(success, "GemBots: transfer failed");

        emit Claimed(_poolId, msg.sender, payout);
    }

    /**
     * @notice Refund bet for a cancelled pool.
     */
    function claimRefund(bytes32 _poolId) external nonReentrant onlyInitialized {
        Pool storage p = pools[_poolId];
        require(p.exists, "GemBots: pool not found");
        require(p.status == PoolStatus.Cancelled, "GemBots: not cancelled");

        Bet storage b = bets[_poolId][msg.sender];
        require(b.exists, "GemBots: no bet found");
        require(!b.claimed, "GemBots: already refunded");

        uint256 refundAmount = b.amount;

        // Effects before interaction
        b.claimed = true;
        b.payout = 0;

        // Interaction
        (bool success, ) = payable(msg.sender).call{value: refundAmount}("");
        require(success, "GemBots: refund failed");

        emit RefundClaimed(_poolId, msg.sender, refundAmount);
    }

    // ──────────────────────────────────────────────
    //  Fee collection
    // ──────────────────────────────────────────────
    /**
     * @notice Collect accumulated fees from a resolved pool and send to treasury.
     */
    function collectFees(bytes32 _poolId) external onlyOwner nonReentrant onlyInitialized {
        Pool storage p = pools[_poolId];
        require(p.exists, "GemBots: pool not found");
        require(p.status == PoolStatus.Resolved, "GemBots: not resolved");
        require(!p.feesCollected, "GemBots: fees already collected");

        // Fee is taken from the losing side only (same as Solana contract)
        uint256 winningPool = p.winner == Side.A ? p.poolA : p.poolB;
        uint256 totalPool = p.poolA + p.poolB;
        uint256 losingPool = totalPool - winningPool;
        uint256 feeAmount = (losingPool * uint256(p.feeBps)) / 10000;

        // Effects before interaction
        p.feesCollected = true;

        // Interaction
        (bool success, ) = payable(treasury).call{value: feeAmount}("");
        require(success, "GemBots: fee transfer failed");

        emit FeesCollected(_poolId, treasury, feeAmount);
    }

    // ──────────────────────────────────────────────
    //  Config
    // ──────────────────────────────────────────────
    /**
     * @notice Update contract configuration.
     * @param _newTreasury New treasury address (address(0) = no change).
     * @param _newFeeBps   New default fee bps (0 = no change).
     * @param _newOwner    New owner address (address(0) = no change).
     */
    function updateConfig(
        address _newTreasury,
        uint16 _newFeeBps,
        address _newOwner
    ) external onlyOwner onlyInitialized {
        if (_newTreasury != address(0)) {
            treasury = _newTreasury;
        }
        if (_newFeeBps > 0) {
            require(_newFeeBps <= MAX_FEE_BPS, "GemBots: fee too high");
            defaultFeeBps = _newFeeBps;
        }
        if (_newOwner != address(0)) {
            owner = _newOwner;
        }

        emit ConfigUpdated(
            owner,
            treasury,
            defaultFeeBps
        );
    }

    // ──────────────────────────────────────────────
    //  View helpers
    // ──────────────────────────────────────────────
    function getPool(bytes32 _poolId) external view returns (Pool memory) {
        require(pools[_poolId].exists, "GemBots: pool not found");
        return pools[_poolId];
    }

    function getBet(bytes32 _poolId, address _bettor) external view returns (Bet memory) {
        require(bets[_poolId][_bettor].exists, "GemBots: bet not found");
        return bets[_poolId][_bettor];
    }

    function getPoolId(string calldata _matchId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(_matchId));
    }

    function getPoolCount() external view returns (uint256) {
        return poolIds.length;
    }

    // ──────────────────────────────────────────────
    //  Fallback — reject random BNB
    // ──────────────────────────────────────────────
    receive() external payable {
        revert("GemBots: use placeBet");
    }

    fallback() external payable {
        revert("GemBots: invalid call");
    }
}
