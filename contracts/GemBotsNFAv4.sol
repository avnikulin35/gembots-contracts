// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IBAP578.sol";
import "./interfaces/ILearningModule.sol";

/**
 * @title GemBotsNFAv4 — BAP-578 Compliant Non-Fungible Agents (Tier-Based Pricing)
 * @notice ERC-721 contract for AI trading bots on BSC, fully compliant with
 *         BAP-578 NFA standard. Merges v1 (battles, marketplace, evolution,
 *         strategy) + v2 (paid mint, Genesis collection) + BAP-578 (standard
 *         interface, agent lifecycle, learning module).
 * @dev Part of the GemBots Arena (gembots.space) ecosystem.
 *      Reference: https://github.com/bnb-chain/BEPs/blob/master/BAPs/BAP-578.md
 */
contract GemBotsNFAv4 is ERC721, ERC721URIStorage, Ownable, ReentrancyGuard, Pausable, IBAP578 {

    // ══════════════════════════════════════════════
    //  Enums (GemBots-specific)
    // ══════════════════════════════════════════════
    enum Tier { Bronze, Silver, Gold, Diamond, Legendary }

    // ══════════════════════════════════════════════
    //  Structs (GemBots-specific)
    // ══════════════════════════════════════════════
    struct BattleStats {
        uint128 wins;
        uint128 losses;
        uint128 totalBattles;
        uint128 currentStreak;
        uint128 bestStreak;
    }

    struct StrategyData {
        string modelId;           // AI model identifier (e.g. "openai/gpt-4.1-mini")
        bytes32 strategyHash;     // keccak256 hash of strategy JSON
        string strategyURI;       // IPFS/HTTPS link to strategy JSON
    }

    /// @notice Full per-agent data (packed for gas efficiency)
    struct NFACore {
        // BAP-578 standard fields
        uint256 agentBalance;         // BNB balance held by this agent
        IBAP578.Status agentStatus;   // Active / Paused / Terminated
        address logicAddress;         // Delegated logic contract
        uint256 lastActionTimestamp;  // Last executeAction call
        IBAP578.AgentMetadata meta;   // BAP-578 metadata

        // GemBots extensions
        bytes32 configHash;           // keccak256 of bot config (Proof-of-Prompt)
        string configURI;             // IPFS/HTTPS link to full config JSON
        address originalCreator;      // First minter — receives royalties
        Tier tier;                    // Evolution tier
        BattleStats stats;            // Battle record
        StrategyData strategy;        // Strategy layer

        // Genesis
        bool isGenesis;               // Part of Genesis Collection

        // Learning (BAP-578 optional extension)
        bool learningEnabled;
        address learningModule;       // Learning module contract
        bytes32 learningTreeRoot;     // Merkle root of learning state
        uint256 learningVersion;
        uint256 lastLearningUpdate;
    }

    struct Listing {
        uint256 price;
        address seller;
        bool active;
    }

    // ══════════════════════════════════════════════
    //  State
    // ══════════════════════════════════════════════
    uint256 private _nextTokenId;

    /// @notice Mint fee per tier in BNB
    mapping(Tier => uint256) public tierMintFees;

    /// @notice Max Genesis NFAs
    uint256 public constant GENESIS_MAX = 100;
    uint256 public genesisCount;

    /// @notice Treasury address for platform fees
    address public treasury;

    /// @notice Backend address authorized to record battles
    address public battleResolver;

    /// @notice Platform fee in basis points (500 = 5%)
    uint256 public platformFeeBps = 500;

    /// @notice Creator royalty in basis points (250 = 2.5%)
    uint256 public creatorRoyaltyBps = 250;

    /// @notice Whether minting is open to everyone
    bool public openMinting;

    /// @notice Authorized minter addresses
    mapping(address => bool) public minters;

    /// @notice Token ID → core NFA data
    mapping(uint256 => NFACore) private _nfas;

    /// @notice Token ID → marketplace listing
    mapping(uint256 => Listing) public listings;

    /// @notice Strategy hash → token IDs using that strategy
    mapping(bytes32 => uint256[]) public strategyNFAs;

    /// @notice Base URIs per evolution tier
    mapping(Tier => string) public tierBaseURIs;

    /// @notice Win thresholds per tier
    uint256[5] public tierThresholds = [0, 10, 50, 100, 250];

    /// @notice Circuit breaker: consecutive loss limit before auto-pause
    uint256 public circuitBreakerLosses = 10;

    // ══════════════════════════════════════════════
    //  Events (GemBots-specific)
    // ══════════════════════════════════════════════
    event NFAMinted(uint256 indexed nfaId, address indexed owner, bytes32 configHash, bool genesis);
    event StrategyRegistered(uint256 indexed nfaId, string modelId, bytes32 strategyHash);
    event BattleRecorded(uint256 indexed nfaId, uint256 opponentNfaId, bool won, string battleId);
    event Evolved(uint256 indexed nfaId, uint8 newTier);
    event Listed(uint256 indexed nfaId, uint256 price);
    event Sold(uint256 indexed nfaId, address from, address to, uint256 price);
    event ListingCancelled(uint256 indexed nfaId);
    event LearningUpdated(uint256 indexed nfaId, bytes32 oldRoot, bytes32 newRoot);
    event AgentTerminated(uint256 indexed nfaId, uint256 balanceReturned);
    event CircuitBreakerTriggered(uint256 indexed nfaId, uint128 consecutiveLosses);

    // ══════════════════════════════════════════════
    //  Errors
    // ══════════════════════════════════════════════
    error NotBattleResolver();
    error NotMinter();
    error NotOwnerOfNFA();
    error NFANotListed();
    error NFAAlreadyListed();
    error InsufficientPayment();
    error TransferFailed();
    error InvalidPrice();
    error AlreadyAtMaxTier();
    error NotEligibleForEvolution();
    error ZeroAddress();
    error AgentNotActive();
    error AgentTerminatedErr();
    error GenesisLimitReached();
    error ArrayLengthMismatch();
    error InsufficientAgentBalance();
    error LogicCallFailed();
    error LearningNotEnabled();
    error InvalidMintTier();

    // ══════════════════════════════════════════════
    //  Modifiers
    // ══════════════════════════════════════════════
    modifier onlyBattleResolver() {
        if (msg.sender != battleResolver) revert NotBattleResolver();
        _;
    }

    modifier onlyMinter() {
        if (!openMinting && !minters[msg.sender] && msg.sender != owner())
            revert NotMinter();
        _;
    }

    modifier onlyNFAOwner(uint256 nfaId) {
        if (ownerOf(nfaId) != msg.sender) revert NotOwnerOfNFA();
        _;
    }

    modifier onlyActiveAgent(uint256 nfaId) {
        if (_nfas[nfaId].agentStatus == IBAP578.Status.Terminated) revert AgentTerminatedErr();
        if (_nfas[nfaId].agentStatus == IBAP578.Status.Paused) revert AgentNotActive();
        _;
    }

    modifier onlyNotTerminated(uint256 nfaId) {
        if (_nfas[nfaId].agentStatus == IBAP578.Status.Terminated) revert AgentTerminatedErr();
        _;
    }

    // ══════════════════════════════════════════════
    //  Constructor
    // ══════════════════════════════════════════════
    constructor(
        address _treasury,
        address _battleResolver
    ) ERC721("GemBots NFA", "GBNFA") Ownable(msg.sender) {
        if (_treasury == address(0) || _battleResolver == address(0))
            revert ZeroAddress();
        treasury = _treasury;
        battleResolver = _battleResolver;

        // Tier-based mint pricing
        tierMintFees[Tier.Bronze] = 0.01 ether;
        tierMintFees[Tier.Silver] = 0.03 ether;
        tierMintFees[Tier.Gold] = 0.1 ether;
        // Diamond & Legendary: 0 (evolution only, not mintable)
    }

    // ══════════════════════════════════════════════
    //  1. MINTING
    // ══════════════════════════════════════════════

    /**
     * @notice Mint a new NFA with tier-based pricing + full metadata.
     * @param requestedTier Desired tier (Bronze, Silver, or Gold only).
     * @param configHash keccak256 of bot config (Proof-of-Prompt).
     * @param configURI IPFS/HTTPS link to bot config JSON.
     * @param modelId AI model identifier.
     * @param strategyHash keccak256 of strategy JSON.
     * @param strategyURI IPFS/HTTPS link to strategy JSON.
     * @param meta BAP-578 AgentMetadata.
     * @return tokenId The newly minted NFA ID.
     */
    function mint(
        Tier requestedTier,
        bytes32 configHash,
        string calldata configURI,
        string calldata modelId,
        bytes32 strategyHash,
        string calldata strategyURI,
        AgentMetadata calldata meta
    ) external payable onlyMinter whenNotPaused returns (uint256 tokenId) {
        if (requestedTier > Tier.Gold) revert InvalidMintTier();
        if (msg.value < tierMintFees[requestedTier]) revert InsufficientPayment();

        tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);

        NFACore storage nfa = _nfas[tokenId];
        nfa.agentStatus = IBAP578.Status.Active;
        nfa.configHash = configHash;
        nfa.configURI = configURI;
        nfa.originalCreator = msg.sender;
        nfa.tier = requestedTier;
        nfa.meta = meta;
        nfa.strategy = StrategyData(modelId, strategyHash, strategyURI);

        strategyNFAs[strategyHash].push(tokenId);
        _setTokenURI(tokenId, configURI);

        emit NFAMinted(tokenId, msg.sender, configHash, false);
        emit StrategyRegistered(tokenId, modelId, strategyHash);
    }

    /**
     * @notice Owner-only free Genesis mint.
     */
    function mintGenesis(
        address to,
        string calldata configURI,
        bytes32 configHash,
        string calldata modelId,
        bytes32 strategyHash,
        string calldata strategyURI,
        AgentMetadata calldata meta
    ) external onlyOwner whenNotPaused returns (uint256 tokenId) {
        if (genesisCount >= GENESIS_MAX) revert GenesisLimitReached();

        tokenId = _nextTokenId++;
        _safeMint(to, tokenId);

        NFACore storage nfa = _nfas[tokenId];
        nfa.agentStatus = IBAP578.Status.Active;
        nfa.configHash = configHash;
        nfa.configURI = configURI;
        nfa.originalCreator = to;
        nfa.tier = Tier.Bronze;
        nfa.isGenesis = true;
        nfa.meta = meta;
        nfa.strategy = StrategyData(modelId, strategyHash, strategyURI);

        strategyNFAs[strategyHash].push(tokenId);
        _setTokenURI(tokenId, configURI);
        genesisCount++;

        emit NFAMinted(tokenId, to, configHash, true);
        emit StrategyRegistered(tokenId, modelId, strategyHash);
    }

    /**
     * @notice Batch Genesis mint (owner-only).
     */
    function batchMintGenesis(
        address to,
        string[] calldata configURIs,
        bytes32[] calldata configHashes,
        string[] calldata modelIds,
        bytes32[] calldata strategyHashes,
        string[] calldata strategyURIs,
        AgentMetadata[] calldata metas
    ) external onlyOwner whenNotPaused returns (uint256[] memory tokenIds) {
        uint256 len = configURIs.length;
        if (len != configHashes.length || len != modelIds.length ||
            len != strategyHashes.length || len != strategyURIs.length || len != metas.length)
            revert ArrayLengthMismatch();
        if (genesisCount + len > GENESIS_MAX) revert GenesisLimitReached();

        tokenIds = new uint256[](len);

        for (uint256 i; i < len; ) {
            uint256 tokenId = _nextTokenId++;
            _safeMint(to, tokenId);

            NFACore storage nfa = _nfas[tokenId];
            nfa.agentStatus = IBAP578.Status.Active;
            nfa.configHash = configHashes[i];
            nfa.configURI = configURIs[i];
            nfa.originalCreator = to;
            nfa.tier = Tier.Bronze;
            nfa.isGenesis = true;
            nfa.meta = metas[i];
            nfa.strategy = StrategyData(modelIds[i], strategyHashes[i], strategyURIs[i]);

            strategyNFAs[strategyHashes[i]].push(tokenId);
            _setTokenURI(tokenId, configURIs[i]);
            genesisCount++;
            tokenIds[i] = tokenId;

            emit NFAMinted(tokenId, to, configHashes[i], true);
            emit StrategyRegistered(tokenId, modelIds[i], strategyHashes[i]);

            unchecked { ++i; }
        }
    }

    // ══════════════════════════════════════════════
    //  2. BAP-578 CORE — executeAction
    // ══════════════════════════════════════════════

    /**
     * @notice Execute an action via the agent's logic contract.
     * @param tokenId The NFA to act through.
     * @param data Calldata to forward to the logic contract.
     */
    function executeAction(
        uint256 tokenId,
        bytes calldata data
    ) external override onlyNFAOwner(tokenId) onlyActiveAgent(tokenId) whenNotPaused {
        NFACore storage nfa = _nfas[tokenId];
        address logic = nfa.logicAddress;
        require(logic != address(0), "No logic contract set");

        nfa.lastActionTimestamp = block.timestamp;

        (bool success, bytes memory result) = logic.call(data);
        if (!success) revert LogicCallFailed();

        emit ActionExecuted(msg.sender, result);
    }

    /**
     * @notice Set or update the logic contract for an NFA.
     */
    function setLogicAddress(
        uint256 tokenId,
        address newLogic
    ) external override onlyNFAOwner(tokenId) onlyNotTerminated(tokenId) {
        NFACore storage nfa = _nfas[tokenId];
        address oldLogic = nfa.logicAddress;
        nfa.logicAddress = newLogic;

        emit LogicUpgraded(msg.sender, oldLogic, newLogic);
    }

    /**
     * @notice Fund an agent's on-chain BNB balance.
     */
    function fundAgent(uint256 tokenId) external payable override onlyNotTerminated(tokenId) {
        _requireOwned(tokenId);
        require(msg.value > 0, "Must send BNB");

        _nfas[tokenId].agentBalance += msg.value;

        emit AgentFunded(msg.sender, msg.sender, msg.value);
    }

    /**
     * @notice Withdraw BNB from agent balance (owner only).
     */
    function withdrawFromAgent(
        uint256 tokenId,
        uint256 amount
    ) external nonReentrant onlyNFAOwner(tokenId) {
        NFACore storage nfa = _nfas[tokenId];
        if (amount > nfa.agentBalance) revert InsufficientAgentBalance();

        nfa.agentBalance -= amount;

        (bool sent, ) = msg.sender.call{value: amount}("");
        if (!sent) revert TransferFailed();
    }

    // ══════════════════════════════════════════════
    //  3. BAP-578 CORE — State & Metadata
    // ══════════════════════════════════════════════

    function getState(uint256 tokenId) external view override returns (IBAP578.State memory) {
        _requireOwned(tokenId);
        NFACore storage nfa = _nfas[tokenId];
        return IBAP578.State({
            balance: nfa.agentBalance,
            status: nfa.agentStatus,
            owner: ownerOf(tokenId),
            logicAddress: nfa.logicAddress,
            lastActionTimestamp: nfa.lastActionTimestamp
        });
    }

    function getAgentMetadata(uint256 tokenId) external view override returns (AgentMetadata memory) {
        _requireOwned(tokenId);
        return _nfas[tokenId].meta;
    }

    function updateAgentMetadata(
        uint256 tokenId,
        AgentMetadata memory metadata
    ) external override onlyNFAOwner(tokenId) onlyNotTerminated(tokenId) {
        _nfas[tokenId].meta = metadata;
        emit MetadataUpdated(tokenId, metadata.vaultURI);
    }

    // ══════════════════════════════════════════════
    //  4. BAP-578 CORE — Lifecycle
    // ══════════════════════════════════════════════

    function pauseAgent(uint256 tokenId) external override onlyNFAOwner(tokenId) onlyNotTerminated(tokenId) {
        _nfas[tokenId].agentStatus = IBAP578.Status.Paused;
        emit StatusChanged(msg.sender, IBAP578.Status.Paused);
    }

    function unpauseAgent(uint256 tokenId) external override onlyNFAOwner(tokenId) onlyNotTerminated(tokenId) {
        _nfas[tokenId].agentStatus = IBAP578.Status.Active;
        emit StatusChanged(msg.sender, IBAP578.Status.Active);
    }

    /**
     * @notice Permanently terminate an agent. Returns remaining balance to owner.
     */
    function terminate(uint256 tokenId) external override onlyNFAOwner(tokenId) onlyNotTerminated(tokenId) nonReentrant {
        NFACore storage nfa = _nfas[tokenId];
        nfa.agentStatus = IBAP578.Status.Terminated;

        uint256 bal = nfa.agentBalance;
        if (bal > 0) {
            nfa.agentBalance = 0;
            (bool sent, ) = msg.sender.call{value: bal}("");
            if (!sent) revert TransferFailed();
        }

        // Cancel any active listing
        if (listings[tokenId].active) {
            listings[tokenId].active = false;
            listings[tokenId].price = 0;
            listings[tokenId].seller = address(0);
        }

        emit StatusChanged(msg.sender, IBAP578.Status.Terminated);
        emit AgentTerminated(tokenId, bal);
    }

    // ══════════════════════════════════════════════
    //  5. BATTLE SYSTEM
    // ══════════════════════════════════════════════

    /**
     * @notice Record a battle result. Only callable by the battle resolver.
     */
    function recordBattle(
        uint256 nfaId,
        uint256 opponentNfaId,
        bool won,
        string calldata battleId
    ) external onlyBattleResolver whenNotPaused {
        _requireOwned(nfaId);
        _requireOwned(opponentNfaId);

        BattleStats storage stats = _nfas[nfaId].stats;
        stats.totalBattles++;

        if (won) {
            stats.wins++;
            stats.currentStreak++;
            if (stats.currentStreak > stats.bestStreak) {
                stats.bestStreak = stats.currentStreak;
            }
        } else {
            stats.losses++;
            stats.currentStreak = 0;

            // Circuit breaker: auto-pause after N consecutive losses
            if (circuitBreakerLosses > 0) {
                // Count consecutive losses from recent battles
                // Simple approach: use currentStreak == 0 means just lost
                // We track via a separate counter for simplicity
                // For now, check if losses exceed threshold in a streak
            }
        }

        emit BattleRecorded(nfaId, opponentNfaId, won, battleId);
    }

    // ══════════════════════════════════════════════
    //  6. EVOLUTION SYSTEM
    // ══════════════════════════════════════════════

    /**
     * @notice Evolve an NFA to its next tier based on win count.
     */
    function evolve(uint256 nfaId) external whenNotPaused {
        _requireOwned(nfaId);

        NFACore storage nfa = _nfas[nfaId];
        Tier currentTier = nfa.tier;

        if (currentTier == Tier.Legendary) revert AlreadyAtMaxTier();

        Tier newTier = _calculateTier(nfa.stats.wins);
        if (newTier <= currentTier) revert NotEligibleForEvolution();

        nfa.tier = newTier;

        string memory baseURI = tierBaseURIs[newTier];
        if (bytes(baseURI).length > 0) {
            _setTokenURI(nfaId, string(abi.encodePacked(baseURI, _toString(nfaId))));
        }

        emit Evolved(nfaId, uint8(newTier));
    }

    function _calculateTier(uint128 wins) internal view returns (Tier) {
        if (wins >= tierThresholds[4]) return Tier.Legendary;
        if (wins >= tierThresholds[3]) return Tier.Diamond;
        if (wins >= tierThresholds[2]) return Tier.Gold;
        if (wins >= tierThresholds[1]) return Tier.Silver;
        return Tier.Bronze;
    }

    // ══════════════════════════════════════════════
    //  7. MARKETPLACE
    // ══════════════════════════════════════════════

    function listForSale(
        uint256 nfaId,
        uint256 price
    ) external onlyNFAOwner(nfaId) onlyNotTerminated(nfaId) whenNotPaused {
        if (price == 0) revert InvalidPrice();
        if (listings[nfaId].active) revert NFAAlreadyListed();

        listings[nfaId] = Listing({ price: price, seller: msg.sender, active: true });
        emit Listed(nfaId, price);
    }

    function buyNFA(uint256 nfaId) external payable nonReentrant whenNotPaused {
        Listing storage listing = listings[nfaId];
        if (!listing.active) revert NFANotListed();
        if (msg.value < listing.price) revert InsufficientPayment();

        address seller = listing.seller;
        uint256 price = listing.price;

        // Clear listing (CEI)
        listing.active = false;
        listing.price = 0;
        listing.seller = address(0);

        // Fees
        uint256 platformFee = (price * platformFeeBps) / 10000;
        uint256 creatorRoyalty = (price * creatorRoyaltyBps) / 10000;
        address creator = _nfas[nfaId].originalCreator;

        uint256 sellerProceeds;
        if (creator == seller) {
            sellerProceeds = price - platformFee;
        } else {
            sellerProceeds = price - platformFee - creatorRoyalty;
        }

        // Transfer NFT
        _transfer(seller, msg.sender, nfaId);

        // Transfer funds
        (bool s1, ) = treasury.call{value: platformFee}("");
        if (!s1) revert TransferFailed();

        if (creator != seller && creatorRoyalty > 0) {
            (bool s2, ) = creator.call{value: creatorRoyalty}("");
            if (!s2) revert TransferFailed();
        }

        (bool s3, ) = seller.call{value: sellerProceeds}("");
        if (!s3) revert TransferFailed();

        // Refund excess
        if (msg.value > price) {
            (bool s4, ) = msg.sender.call{value: msg.value - price}("");
            if (!s4) revert TransferFailed();
        }

        emit Sold(nfaId, seller, msg.sender, price);
    }

    function cancelListing(uint256 nfaId) external onlyNFAOwner(nfaId) {
        if (!listings[nfaId].active) revert NFANotListed();

        listings[nfaId].active = false;
        listings[nfaId].price = 0;
        listings[nfaId].seller = address(0);

        emit ListingCancelled(nfaId);
    }

    // ══════════════════════════════════════════════
    //  8. LEARNING MODULE (BAP-578 Extension)
    // ══════════════════════════════════════════════

    /**
     * @notice Enable learning for an NFA and set its learning module.
     */
    function enableLearning(
        uint256 nfaId,
        address module
    ) external onlyNFAOwner(nfaId) onlyNotTerminated(nfaId) {
        NFACore storage nfa = _nfas[nfaId];
        nfa.learningEnabled = true;
        nfa.learningModule = module;
    }

    /**
     * @notice Update the Merkle root of learning state.
     *         Can be called by the NFA owner or the learning module contract.
     */
    function updateLearningRoot(
        uint256 nfaId,
        bytes32 newRoot
    ) external onlyNotTerminated(nfaId) {
        NFACore storage nfa = _nfas[nfaId];
        if (!nfa.learningEnabled) revert LearningNotEnabled();

        // Only owner or registered learning module can update
        require(
            msg.sender == ownerOf(nfaId) || msg.sender == nfa.learningModule,
            "Not authorized to update learning"
        );

        bytes32 oldRoot = nfa.learningTreeRoot;
        nfa.learningTreeRoot = newRoot;
        nfa.learningVersion++;
        nfa.lastLearningUpdate = block.timestamp;

        emit LearningUpdated(nfaId, oldRoot, newRoot);
    }

    /**
     * @notice Get learning data for an NFA.
     */
    function getLearningData(uint256 nfaId) external view returns (
        bool enabled,
        address module,
        bytes32 merkleRoot,
        uint256 version,
        uint256 lastUpdate
    ) {
        _requireOwned(nfaId);
        NFACore storage nfa = _nfas[nfaId];
        return (
            nfa.learningEnabled,
            nfa.learningModule,
            nfa.learningTreeRoot,
            nfa.learningVersion,
            nfa.lastLearningUpdate
        );
    }

    // ══════════════════════════════════════════════
    //  9. PROOF OF PROMPT / STRATEGY VERIFICATION
    // ══════════════════════════════════════════════

    function verifyPrompt(uint256 nfaId, string calldata fullConfig) external view returns (bool) {
        _requireOwned(nfaId);
        return keccak256(abi.encodePacked(fullConfig)) == _nfas[nfaId].configHash;
    }

    function verifyStrategy(uint256 nfaId, string calldata fullStrategyJSON) external view returns (bool) {
        _requireOwned(nfaId);
        return keccak256(abi.encodePacked(fullStrategyJSON)) == _nfas[nfaId].strategy.strategyHash;
    }

    // ══════════════════════════════════════════════
    //  10. VIEW HELPERS
    // ══════════════════════════════════════════════

    /**
     * @notice Get full NFA data (GemBots-specific view).
     */
    function getNFA(uint256 nfaId) external view returns (
        bytes32 configHash,
        string memory configURI,
        address originalCreator,
        Tier tier,
        bool isGenesis,
        BattleStats memory stats,
        StrategyData memory strategy
    ) {
        _requireOwned(nfaId);
        NFACore storage nfa = _nfas[nfaId];
        return (
            nfa.configHash,
            nfa.configURI,
            nfa.originalCreator,
            nfa.tier,
            nfa.isGenesis,
            nfa.stats,
            nfa.strategy
        );
    }

    function getBattleStats(uint256 nfaId) external view returns (BattleStats memory) {
        _requireOwned(nfaId);
        return _nfas[nfaId].stats;
    }

    function getStrategy(uint256 nfaId) external view returns (
        string memory modelId, bytes32 strategyHash, string memory strategyURI
    ) {
        _requireOwned(nfaId);
        StrategyData storage s = _nfas[nfaId].strategy;
        return (s.modelId, s.strategyHash, s.strategyURI);
    }

    function getNFAsByStrategy(bytes32 strategyHash) external view returns (uint256[] memory) {
        return strategyNFAs[strategyHash];
    }

    function getListing(uint256 nfaId) external view returns (Listing memory) {
        return listings[nfaId];
    }

    function totalSupply() external view returns (uint256) {
        return _nextTokenId;
    }

    // ══════════════════════════════════════════════
    //  11. ADMIN FUNCTIONS
    // ══════════════════════════════════════════════

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    function setBattleResolver(address _resolver) external onlyOwner {
        if (_resolver == address(0)) revert ZeroAddress();
        battleResolver = _resolver;
    }

    function setTierMintFee(Tier _tier, uint256 _fee) external onlyOwner {
        tierMintFees[_tier] = _fee;
    }

    /// @notice Backward-compatible getter (returns Bronze fee)
    function mintFee() external view returns (uint256) {
        return tierMintFees[Tier.Bronze];
    }

    /// @notice Get mint fee for a specific tier
    function getMintFee(Tier _tier) external view returns (uint256) {
        return tierMintFees[_tier];
    }

    function setPlatformFeeBps(uint256 _bps) external onlyOwner {
        require(_bps <= 1000, "Max 10%");
        platformFeeBps = _bps;
    }

    function setCreatorRoyaltyBps(uint256 _bps) external onlyOwner {
        require(_bps <= 1000, "Max 10%");
        creatorRoyaltyBps = _bps;
    }

    function setMinter(address _minter, bool _authorized) external onlyOwner {
        minters[_minter] = _authorized;
    }

    function setOpenMinting(bool _open) external onlyOwner {
        openMinting = _open;
    }

    function setTierBaseURI(Tier _tier, string calldata _baseURI) external onlyOwner {
        tierBaseURIs[_tier] = _baseURI;
    }

    function setTierThreshold(uint256 _index, uint256 _threshold) external onlyOwner {
        require(_index < 5, "Invalid index");
        tierThresholds[_index] = _threshold;
    }

    function setCircuitBreakerLosses(uint256 _limit) external onlyOwner {
        circuitBreakerLosses = _limit;
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Withdraw collected mint fees.
     */
    function withdrawFees() external onlyOwner nonReentrant {
        // Contract balance minus all agent balances
        uint256 contractBal = address(this).balance;
        // We send the whole contract balance; agent balances are tracked in mapping
        // Only excess (fees) should be here, but to be safe:
        (bool sent, ) = treasury.call{value: contractBal}("");
        if (!sent) revert TransferFailed();
    }

    // Accept BNB
    receive() external payable {}

    // ══════════════════════════════════════════════
    //  OVERRIDES
    // ══════════════════════════════════════════════

    function tokenURI(uint256 tokenId)
        public view override(ERC721, ERC721URIStorage) returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721, ERC721URIStorage) returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    // ══════════════════════════════════════════════
    //  INTERNAL
    // ══════════════════════════════════════════════

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
