// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./interfaces/ILearningModule.sol";

/**
 * @title GemBotsLearning — BAP-578 Learning Module for GemBots Arena
 * @notice Manages on-chain learning records for GemBots NFAs using Merkle trees.
 *         Battle outcomes, strategy adaptations, and performance metrics are
 *         hashed into a Merkle tree. Only the 32-byte root is stored on-chain.
 * @dev Designed to be registered as the learningModule on GemBotsNFAv3.
 */
contract GemBotsLearning is ILearningModule, Ownable {

    /// @notice Reference to the main NFA contract
    address public nfaContract;

    /// @notice Authorized updaters (battle resolver, backend)
    mapping(address => bool) public updaters;

    /// @notice Token ID → learning metrics
    mapping(uint256 => LearningMetrics) private _metrics;

    /// @notice Token ID → current Merkle root
    mapping(uint256 => bytes32) private _roots;

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────
    error NotAuthorized();
    error InvalidRoot();
    error RootMismatch();

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────
    modifier onlyUpdater() {
        if (!updaters[msg.sender] && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────
    constructor(address _nfaContract) Ownable(msg.sender) {
        nfaContract = _nfaContract;
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    function setUpdater(address _updater, bool _authorized) external onlyOwner {
        updaters[_updater] = _authorized;
    }

    function setNFAContract(address _nfa) external onlyOwner {
        nfaContract = _nfa;
    }

    // ──────────────────────────────────────────────
    //  ILearningModule Implementation
    // ──────────────────────────────────────────────

    /**
     * @notice Update learning state after a battle or strategy change.
     * @param tokenId The NFA token ID.
     * @param update Learning update containing old root, new root, and proof.
     */
    function updateLearning(
        uint256 tokenId,
        LearningUpdate calldata update
    ) external override onlyUpdater {
        bytes32 currentRoot = _roots[tokenId];

        // Verify previous root matches (prevent stale updates)
        if (currentRoot != bytes32(0) && update.previousRoot != currentRoot)
            revert RootMismatch();

        if (update.newRoot == bytes32(0)) revert InvalidRoot();

        bytes32 oldRoot = _roots[tokenId];
        _roots[tokenId] = update.newRoot;

        // Update metrics
        LearningMetrics storage m = _metrics[tokenId];
        m.totalInteractions++;
        m.learningEvents++;
        m.lastUpdateTimestamp = block.timestamp;

        // Calculate learning velocity (events per hour, scaled by 1e18)
        if (m.learningEvents > 1 && m.lastUpdateTimestamp > 0) {
            uint256 elapsed = block.timestamp - m.lastUpdateTimestamp;
            if (elapsed > 0) {
                m.learningVelocity = (m.learningEvents * 1e18 * 3600) / elapsed;
            }
        }

        // Confidence grows with more data (asymptotic approach to 1e18)
        // confidence = 1 - 1/(1 + events/100)
        m.confidenceScore = (m.learningEvents * 1e18) / (m.learningEvents + 100);

        emit LearningUpdated(tokenId, oldRoot, update.newRoot);
    }

    /**
     * @notice Verify a learning claim against the Merkle tree.
     * @param tokenId The NFA token ID.
     * @param claim The leaf hash to verify.
     * @param proof The Merkle proof path.
     * @return True if the claim is part of the learning tree.
     */
    function verifyLearning(
        uint256 tokenId,
        bytes32 claim,
        bytes32[] calldata proof
    ) external view override returns (bool) {
        bytes32 root = _roots[tokenId];
        if (root == bytes32(0)) return false;
        return MerkleProof.verify(proof, root, claim);
    }

    /**
     * @notice Get learning metrics for an NFA.
     */
    function getLearningMetrics(
        uint256 tokenId
    ) external view override returns (LearningMetrics memory) {
        return _metrics[tokenId];
    }

    /**
     * @notice Get the current Merkle root.
     */
    function getLearningRoot(uint256 tokenId) external view override returns (bytes32) {
        return _roots[tokenId];
    }

    // ──────────────────────────────────────────────
    //  Batch Operations (gas-efficient for battle resolver)
    // ──────────────────────────────────────────────

    /**
     * @notice Record battle-based learning for multiple NFAs at once.
     * @param tokenIds Array of NFA token IDs.
     * @param newRoots Array of new Merkle roots.
     */
    function batchUpdateRoots(
        uint256[] calldata tokenIds,
        bytes32[] calldata newRoots
    ) external onlyUpdater {
        require(tokenIds.length == newRoots.length, "Length mismatch");

        for (uint256 i; i < tokenIds.length; ) {
            if (newRoots[i] != bytes32(0)) {
                bytes32 oldRoot = _roots[tokenIds[i]];
                _roots[tokenIds[i]] = newRoots[i];

                LearningMetrics storage m = _metrics[tokenIds[i]];
                m.totalInteractions++;
                m.learningEvents++;
                m.lastUpdateTimestamp = block.timestamp;
                m.confidenceScore = (m.learningEvents * 1e18) / (m.learningEvents + 100);

                emit LearningUpdated(tokenIds[i], oldRoot, newRoots[i]);
            }

            unchecked { ++i; }
        }
    }

    /**
     * @notice Record a battle interaction without changing the Merkle root.
     *         Used to track interaction count even for non-learning-update battles.
     */
    function recordInteraction(uint256 tokenId) external onlyUpdater {
        _metrics[tokenId].totalInteractions++;
    }
}
