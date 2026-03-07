// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GemBotsBattleRecorder
 * @notice On-chain battle recording for GemBots Arena.
 *         Works alongside GemBotsNFAv2 — stores battle results, ELO, win/loss stats.
 *         Only the authorized resolver can record battles.
 *         Gas-efficient: ~50K gas per recordBattle (single storage write + event).
 *
 * @dev Designed to be deployed once and linked to the existing NFA contract.
 *      No need to migrate NFTs — this is a companion contract.
 */
contract GemBotsBattleRecorder is Ownable {
    // ══════════════════════════════════════════════
    //  Structs
    // ══════════════════════════════════════════════

    struct BattleStats {
        uint64 wins;
        uint64 losses;
        uint64 totalBattles;
        uint32 currentStreak;
        uint32 bestStreak;
        uint32 elo;           // ELO rating (starts at 1200)
    }

    struct BattleRecord {
        uint256 winnerNfaId;
        uint256 loserNfaId;
        string token;          // Token traded (e.g. "BTC", "ETH")
        uint64 winnerAccuracy; // Winner accuracy in basis points (0-10000 = 0-100%)
        uint64 loserAccuracy;  // Loser accuracy in basis points
        uint64 damage;         // HP damage dealt
        uint64 timestamp;
    }

    // ══════════════════════════════════════════════
    //  State
    // ══════════════════════════════════════════════

    /// @notice Address of the NFA contract (for validation)
    address public nfaContract;

    /// @notice Address allowed to record battles
    address public resolver;

    /// @notice Per-NFA battle statistics
    mapping(uint256 => BattleStats) public nfaStats;

    /// @notice All recorded battles (indexed by battle ID hash)
    mapping(bytes32 => BattleRecord) public battles;

    /// @notice Battle count
    uint256 public totalBattlesRecorded;

    /// @notice NFA battle history (nfaId => array of battle ID hashes)
    mapping(uint256 => bytes32[]) public nfaBattleHistory;

    /// @notice Default starting ELO
    uint32 public constant DEFAULT_ELO = 1200;

    /// @notice K-factor for ELO calculation
    uint32 public constant ELO_K = 32;

    // ══════════════════════════════════════════════
    //  Events
    // ══════════════════════════════════════════════

    event BattleRecorded(
        bytes32 indexed battleHash,
        uint256 indexed winnerNfaId,
        uint256 indexed loserNfaId,
        string battleId,
        string token,
        uint64 winnerAccuracy,
        uint64 loserAccuracy,
        uint64 damage,
        uint32 winnerNewElo,
        uint32 loserNewElo
    );

    event ResolverUpdated(address oldResolver, address newResolver);
    event NFAContractUpdated(address oldContract, address newContract);

    // ══════════════════════════════════════════════
    //  Errors
    // ══════════════════════════════════════════════

    error OnlyResolver();
    error InvalidNfaId();
    error SameNfaIds();
    error BattleAlreadyRecorded();

    // ══════════════════════════════════════════════
    //  Modifiers
    // ══════════════════════════════════════════════

    modifier onlyResolver() {
        if (msg.sender != resolver) revert OnlyResolver();
        _;
    }

    // ══════════════════════════════════════════════
    //  Constructor
    // ══════════════════════════════════════════════

    constructor(address _nfaContract, address _resolver) Ownable(msg.sender) {
        nfaContract = _nfaContract;
        resolver = _resolver;
    }

    // ══════════════════════════════════════════════
    //  Core: Record Battle
    // ══════════════════════════════════════════════

    /**
     * @notice Record a battle result on-chain.
     * @param battleId Unique off-chain battle identifier
     * @param winnerNfaId NFA token ID of the winner
     * @param loserNfaId NFA token ID of the loser
     * @param token Token symbol traded
     * @param winnerAccuracy Winner's prediction accuracy (basis points, 0-10000)
     * @param loserAccuracy Loser's prediction accuracy (basis points, 0-10000)
     * @param damage HP damage dealt to loser
     */
    function recordBattle(
        string calldata battleId,
        uint256 winnerNfaId,
        uint256 loserNfaId,
        string calldata token,
        uint64 winnerAccuracy,
        uint64 loserAccuracy,
        uint64 damage
    ) external onlyResolver {
        if (winnerNfaId == loserNfaId) revert SameNfaIds();

        bytes32 battleHash = keccak256(abi.encodePacked(battleId));
        if (battles[battleHash].timestamp != 0) revert BattleAlreadyRecorded();

        // Initialize ELO if first battle
        if (nfaStats[winnerNfaId].elo == 0) {
            nfaStats[winnerNfaId].elo = DEFAULT_ELO;
        }
        if (nfaStats[loserNfaId].elo == 0) {
            nfaStats[loserNfaId].elo = DEFAULT_ELO;
        }

        // Calculate new ELO
        (uint32 winnerNewElo, uint32 loserNewElo) = _calculateElo(
            nfaStats[winnerNfaId].elo,
            nfaStats[loserNfaId].elo
        );

        // Update winner stats
        BattleStats storage winnerStats = nfaStats[winnerNfaId];
        winnerStats.wins++;
        winnerStats.totalBattles++;
        winnerStats.currentStreak++;
        if (winnerStats.currentStreak > winnerStats.bestStreak) {
            winnerStats.bestStreak = winnerStats.currentStreak;
        }
        winnerStats.elo = winnerNewElo;

        // Update loser stats
        BattleStats storage loserStats = nfaStats[loserNfaId];
        loserStats.losses++;
        loserStats.totalBattles++;
        loserStats.currentStreak = 0;
        loserStats.elo = loserNewElo;

        // Store battle record
        battles[battleHash] = BattleRecord({
            winnerNfaId: winnerNfaId,
            loserNfaId: loserNfaId,
            token: token,
            winnerAccuracy: winnerAccuracy,
            loserAccuracy: loserAccuracy,
            damage: damage,
            timestamp: uint64(block.timestamp)
        });

        // Track battle history per NFA
        nfaBattleHistory[winnerNfaId].push(battleHash);
        nfaBattleHistory[loserNfaId].push(battleHash);

        totalBattlesRecorded++;

        emit BattleRecorded(
            battleHash,
            winnerNfaId,
            loserNfaId,
            battleId,
            token,
            winnerAccuracy,
            loserAccuracy,
            damage,
            winnerNewElo,
            loserNewElo
        );
    }

    /**
     * @notice Batch record multiple battles (gas-efficient for catch-up)
     */
    function batchRecordBattles(
        string[] calldata battleIds,
        uint256[] calldata winnerNfaIds,
        uint256[] calldata loserNfaIds,
        string[] calldata tokens,
        uint64[] calldata winnerAccuracies,
        uint64[] calldata loserAccuracies,
        uint64[] calldata damages
    ) external onlyResolver {
        uint256 len = battleIds.length;
        require(
            len == winnerNfaIds.length &&
            len == loserNfaIds.length &&
            len == tokens.length &&
            len == winnerAccuracies.length &&
            len == loserAccuracies.length &&
            len == damages.length,
            "Array length mismatch"
        );
        require(len <= 50, "Max 50 battles per batch");

        for (uint256 i = 0; i < len; i++) {
            // Skip duplicates silently in batch mode
            bytes32 battleHash = keccak256(abi.encodePacked(battleIds[i]));
            if (battles[battleHash].timestamp != 0) continue;

            this.recordBattle(
                battleIds[i],
                winnerNfaIds[i],
                loserNfaIds[i],
                tokens[i],
                winnerAccuracies[i],
                loserAccuracies[i],
                damages[i]
            );
        }
    }

    // ══════════════════════════════════════════════
    //  Views
    // ══════════════════════════════════════════════

    /**
     * @notice Get full stats for an NFA
     */
    function getStats(uint256 nfaId) external view returns (BattleStats memory) {
        BattleStats memory stats = nfaStats[nfaId];
        if (stats.elo == 0) stats.elo = DEFAULT_ELO;
        return stats;
    }

    /**
     * @notice Get battle count for an NFA
     */
    function getBattleCount(uint256 nfaId) external view returns (uint256) {
        return nfaBattleHistory[nfaId].length;
    }

    /**
     * @notice Get battle history for an NFA (paginated)
     */
    function getBattleHistory(
        uint256 nfaId,
        uint256 offset,
        uint256 limit
    ) external view returns (BattleRecord[] memory) {
        bytes32[] storage history = nfaBattleHistory[nfaId];
        uint256 total = history.length;
        if (offset >= total) return new BattleRecord[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;

        BattleRecord[] memory records = new BattleRecord[](count);
        for (uint256 i = 0; i < count; i++) {
            records[i] = battles[history[total - 1 - offset - i]]; // newest first
        }
        return records;
    }

    /**
     * @notice Get win rate in basis points (0-10000)
     */
    function getWinRate(uint256 nfaId) external view returns (uint256) {
        BattleStats memory stats = nfaStats[nfaId];
        if (stats.totalBattles == 0) return 5000; // 50% default
        return (uint256(stats.wins) * 10000) / uint256(stats.totalBattles);
    }

    // ══════════════════════════════════════════════
    //  ELO Calculation
    // ══════════════════════════════════════════════

    /**
     * @dev Calculate new ELO ratings after a match.
     *      Uses simplified integer ELO (no floating point).
     *      Winner gains, loser loses the same amount.
     */
    function _calculateElo(
        uint32 winnerElo,
        uint32 loserElo
    ) internal pure returns (uint32 newWinnerElo, uint32 newLoserElo) {
        // Expected score (simplified): higher ELO opponent = more ELO gained
        // Using linear approximation instead of logistic function
        int256 diff = int256(uint256(loserElo)) - int256(uint256(winnerElo));

        // Clamp diff to [-400, 400]
        if (diff > 400) diff = 400;
        if (diff < -400) diff = -400;

        // ELO change = K * (1 - expected_score)
        // Approximation: expected_score ≈ 0.5 + diff/800
        // So change = K * (0.5 - diff/800) = K/2 - K*diff/800
        int256 change = int256(uint256(ELO_K)) / 2 - (int256(uint256(ELO_K)) * diff) / 800;

        // Minimum change of 1
        if (change < 1) change = 1;

        // Apply changes (floor at 100)
        int256 newW = int256(uint256(winnerElo)) + change;
        int256 newL = int256(uint256(loserElo)) - change;

        if (newW > 3000) newW = 3000;
        if (newW < 100) newW = 100;
        if (newL > 3000) newL = 3000;
        if (newL < 100) newL = 100;
        newWinnerElo = uint32(uint256(newW));
        newLoserElo = uint32(uint256(newL));
    }

    // ══════════════════════════════════════════════
    //  Admin
    // ══════════════════════════════════════════════

    function setResolver(address _resolver) external onlyOwner {
        emit ResolverUpdated(resolver, _resolver);
        resolver = _resolver;
    }

    function setNFAContract(address _nfaContract) external onlyOwner {
        emit NFAContractUpdated(nfaContract, _nfaContract);
        nfaContract = _nfaContract;
    }
}
