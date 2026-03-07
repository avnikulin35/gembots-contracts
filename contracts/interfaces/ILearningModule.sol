// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ILearningModule — BAP-578 Learning Extension
 * @notice Standardized interface for agent learning via Merkle tree proofs.
 *         Only the 32-byte Merkle root is stored on-chain; full learning data
 *         lives off-chain with cryptographic verification.
 */
interface ILearningModule {
    struct LearningMetrics {
        uint256 totalInteractions;    // Total user/battle interactions
        uint256 learningEvents;       // Significant learning updates
        uint256 lastUpdateTimestamp;  // Last learning update time
        uint256 learningVelocity;     // Learning rate (scaled by 1e18)
        uint256 confidenceScore;      // Overall confidence (scaled by 1e18)
    }

    struct LearningUpdate {
        bytes32 previousRoot;   // Previous Merkle root
        bytes32 newRoot;        // New Merkle root after learning
        bytes32 proof;          // Proof of valid transition
        bytes metadata;         // Encoded learning data
    }

    event LearningUpdated(uint256 indexed tokenId, bytes32 oldRoot, bytes32 newRoot);
    event LearningModuleRegistered(uint256 indexed tokenId, address module);

    function updateLearning(uint256 tokenId, LearningUpdate calldata update) external;
    function verifyLearning(uint256 tokenId, bytes32 claim, bytes32[] calldata proof) external view returns (bool);
    function getLearningMetrics(uint256 tokenId) external view returns (LearningMetrics memory);
    function getLearningRoot(uint256 tokenId) external view returns (bytes32);
}
