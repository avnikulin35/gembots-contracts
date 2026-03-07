// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title GemBotsNFA — Non-Fungible Agents
 * @notice ERC-721 contract making AI bots tradeable NFT-agents on BSC.
 *         Each NFA links to an ERC-8004 agent identity, tracks battle history,
 *         evolves through tiers, and can be traded in a built-in marketplace.
 * @dev Part of the GemBots Arena (gembots.space) ecosystem.
 */
contract GemBotsNFA is ERC721, ERC721URIStorage, Ownable, ReentrancyGuard, Pausable {

    // ──────────────────────────────────────────────
    //  Enums
    // ──────────────────────────────────────────────
    enum Tier { Bronze, Silver, Gold, Diamond, Legendary }

    // ──────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────
    struct BattleStats {
        uint256 wins;
        uint256 losses;
        uint256 totalBattles;
        uint256 currentStreak;
        uint256 bestStreak;
    }

    struct NFAData {
        uint256 agentId;          // ERC-8004 agent identity ID
        bytes32 configHash;       // keccak256 of bot config (was proofOfPrompt)
        string configURI;         // IPFS/HTTPS link to full config JSON
        address originalCreator;  // first minter — receives royalties
        Tier tier;
        BattleStats stats;
        // Strategy layer
        string modelId;           // AI model identifier (e.g. "openai/gpt-4.1-mini")
        bytes32 strategyHash;     // keccak256 hash of strategy JSON
        string strategyURI;       // IPFS/HTTPS link to strategy JSON
    }

    struct Listing {
        uint256 price;
        address seller;
        bool active;
    }

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────
    uint256 private _nextTokenId;

    /// @notice Treasury address for platform fees
    address public treasury;

    /// @notice Backend address authorized to record battles
    address public battleResolver;

    /// @notice Platform fee in basis points (500 = 5%)
    uint256 public platformFeeBps = 500;

    /// @notice Creator royalty in basis points (250 = 2.5%)
    uint256 public creatorRoyaltyBps = 250;

    /// @notice Whether minting is open to everyone (vs restricted to minters)
    bool public openMinting;

    /// @notice Authorized minter addresses
    mapping(address => bool) public minters;

    /// @notice Token ID → NFA data
    mapping(uint256 => NFAData) public nfas;

    /// @notice Token ID → marketplace listing
    mapping(uint256 => Listing) public listings;

    /// @notice Strategy hash → list of token IDs using that strategy
    mapping(bytes32 => uint256[]) public strategyNFAs;

    /// @notice Base URIs for each tier (for evolution visuals)
    mapping(Tier => string) public tierBaseURIs;

    /// @notice Win thresholds for each tier
    uint256[5] public tierThresholds = [0, 10, 50, 100, 250];

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────
    event NFAMinted(
        uint256 indexed nfaId,
        uint256 indexed agentId,
        address indexed owner,
        bytes32 configHash
    );

    event StrategyRegistered(
        uint256 indexed nfaId,
        string modelId,
        bytes32 strategyHash
    );

    event BattleRecorded(
        uint256 indexed nfaId,
        uint256 opponentNfaId,
        bool won,
        string battleId
    );

    event Evolved(uint256 indexed nfaId, uint8 newTier);

    event Listed(uint256 indexed nfaId, uint256 price);

    event Sold(
        uint256 indexed nfaId,
        address from,
        address to,
        uint256 price
    );

    event ListingCancelled(uint256 indexed nfaId);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────
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

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────
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

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────
    constructor(
        address _treasury,
        address _battleResolver
    ) ERC721("GemBots NFA", "GBNFA") Ownable(msg.sender) {
        if (_treasury == address(0) || _battleResolver == address(0))
            revert ZeroAddress();
        treasury = _treasury;
        battleResolver = _battleResolver;
    }

    // ──────────────────────────────────────────────
    //  1. Mint NFA
    // ──────────────────────────────────────────────

    /**
     * @notice Mint a new Non-Fungible Agent linked to an ERC-8004 agent identity.
     * @param agentId The ERC-8004 agent identity ID.
     * @param configHash keccak256 hash of bot config (system prompt + temperature + model).
     * @param configURI IPFS/HTTPS link to full bot config JSON.
     * @param modelId AI model identifier (e.g. "openai/gpt-4.1-mini").
     * @param strategyHash keccak256 hash of the strategy JSON.
     * @param strategyURI IPFS/HTTPS link to strategy JSON.
     * @return tokenId The ID of the newly minted NFA.
     */
    function mint(
        uint256 agentId,
        bytes32 configHash,
        string calldata configURI,
        string calldata modelId,
        bytes32 strategyHash,
        string calldata strategyURI
    ) external onlyMinter whenNotPaused returns (uint256 tokenId) {
        tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);

        NFAData storage nfa = nfas[tokenId];
        nfa.agentId = agentId;
        nfa.configHash = configHash;
        nfa.configURI = configURI;
        nfa.originalCreator = msg.sender;
        nfa.tier = Tier.Bronze;
        nfa.modelId = modelId;
        nfa.strategyHash = strategyHash;
        nfa.strategyURI = strategyURI;

        // Index NFA by strategy hash for lookups
        strategyNFAs[strategyHash].push(tokenId);

        // Set initial tokenURI to configURI
        _setTokenURI(tokenId, configURI);

        emit NFAMinted(tokenId, agentId, msg.sender, configHash);
        emit StrategyRegistered(tokenId, modelId, strategyHash);
    }

    // ──────────────────────────────────────────────
    //  2. Battle Record
    // ──────────────────────────────────────────────

    /**
     * @notice Record a battle result for an NFA. Only callable by the battle resolver.
     * @param nfaId The NFA that participated.
     * @param opponentNfaId The opponent NFA.
     * @param won Whether the NFA won.
     * @param battleId External battle identifier string.
     */
    function recordBattle(
        uint256 nfaId,
        uint256 opponentNfaId,
        bool won,
        string calldata battleId
    ) external onlyBattleResolver whenNotPaused {
        // Ensure both NFAs exist
        _requireOwned(nfaId);
        _requireOwned(opponentNfaId);

        BattleStats storage stats = nfas[nfaId].stats;
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
        }

        emit BattleRecorded(nfaId, opponentNfaId, won, battleId);
    }

    // ──────────────────────────────────────────────
    //  3. Evolution System
    // ──────────────────────────────────────────────

    /**
     * @notice Evolve an NFA to its next tier based on win count.
     * @param nfaId The NFA to evolve.
     */
    function evolve(uint256 nfaId) external whenNotPaused {
        _requireOwned(nfaId);

        NFAData storage nfa = nfas[nfaId];
        Tier currentTier = nfa.tier;

        if (currentTier == Tier.Legendary) revert AlreadyAtMaxTier();

        Tier newTier = _calculateTier(nfa.stats.wins);
        if (newTier <= currentTier) revert NotEligibleForEvolution();

        nfa.tier = newTier;

        // Update tokenURI if tier-specific base URI is set
        string memory baseURI = tierBaseURIs[newTier];
        if (bytes(baseURI).length > 0) {
            string memory newURI = string(
                abi.encodePacked(baseURI, _toString(nfaId))
            );
            _setTokenURI(nfaId, newURI);
        }

        emit Evolved(nfaId, uint8(newTier));
    }

    /**
     * @notice Get the tier an NFA qualifies for based on its win count.
     * @param wins Number of wins.
     * @return The corresponding Tier.
     */
    function _calculateTier(uint256 wins) internal view returns (Tier) {
        if (wins >= tierThresholds[4]) return Tier.Legendary;
        if (wins >= tierThresholds[3]) return Tier.Diamond;
        if (wins >= tierThresholds[2]) return Tier.Gold;
        if (wins >= tierThresholds[1]) return Tier.Silver;
        return Tier.Bronze;
    }

    // ──────────────────────────────────────────────
    //  4. Marketplace
    // ──────────────────────────────────────────────

    /**
     * @notice List an NFA for sale.
     * @param nfaId The NFA to list.
     * @param price The sale price in wei.
     */
    function listForSale(
        uint256 nfaId,
        uint256 price
    ) external onlyNFAOwner(nfaId) whenNotPaused {
        if (price == 0) revert InvalidPrice();
        if (listings[nfaId].active) revert NFAAlreadyListed();

        // Seller must have approved this contract to transfer
        listings[nfaId] = Listing({
            price: price,
            seller: msg.sender,
            active: true
        });

        emit Listed(nfaId, price);
    }

    /**
     * @notice Buy a listed NFA.
     * @param nfaId The NFA to buy.
     */
    function buyNFA(
        uint256 nfaId
    ) external payable nonReentrant whenNotPaused {
        Listing storage listing = listings[nfaId];
        if (!listing.active) revert NFANotListed();
        if (msg.value < listing.price) revert InsufficientPayment();

        address seller = listing.seller;
        uint256 price = listing.price;

        // Clear listing before transfers (CEI pattern)
        listing.active = false;
        listing.price = 0;
        listing.seller = address(0);

        // Calculate fees
        uint256 platformFee = (price * platformFeeBps) / 10000;
        uint256 creatorRoyalty = (price * creatorRoyaltyBps) / 10000;
        address creator = nfas[nfaId].originalCreator;

        // If creator is the seller, no royalty — goes to seller
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

    /**
     * @notice Cancel a listing.
     * @param nfaId The NFA to unlist.
     */
    function cancelListing(
        uint256 nfaId
    ) external onlyNFAOwner(nfaId) {
        if (!listings[nfaId].active) revert NFANotListed();

        listings[nfaId].active = false;
        listings[nfaId].price = 0;
        listings[nfaId].seller = address(0);

        emit ListingCancelled(nfaId);
    }

    // ──────────────────────────────────────────────
    //  5. Proof of Prompt
    // ──────────────────────────────────────────────

    /**
     * @notice Verify that a full config string matches the stored configHash.
     * @param nfaId The NFA to verify.
     * @param fullConfig The full config string to hash and compare.
     * @return True if the hash matches.
     */
    function verifyPrompt(
        uint256 nfaId,
        string calldata fullConfig
    ) external view returns (bool) {
        _requireOwned(nfaId);
        return keccak256(abi.encodePacked(fullConfig)) == nfas[nfaId].configHash;
    }

    // ──────────────────────────────────────────────
    //  View Helpers
    // ──────────────────────────────────────────────

    /**
     * @notice Get full NFA data.
     */
    function getNFA(uint256 nfaId) external view returns (
        uint256 agentId,
        bytes32 configHash,
        string memory configURI,
        address originalCreator,
        Tier tier,
        uint256 wins,
        uint256 losses,
        uint256 totalBattles,
        uint256 currentStreak,
        uint256 bestStreak,
        string memory modelId,
        bytes32 strategyHash,
        string memory strategyURI
    ) {
        _requireOwned(nfaId);
        NFAData storage nfa = nfas[nfaId];
        return (
            nfa.agentId,
            nfa.configHash,
            nfa.configURI,
            nfa.originalCreator,
            nfa.tier,
            nfa.stats.wins,
            nfa.stats.losses,
            nfa.stats.totalBattles,
            nfa.stats.currentStreak,
            nfa.stats.bestStreak,
            nfa.modelId,
            nfa.strategyHash,
            nfa.strategyURI
        );
    }

    // ──────────────────────────────────────────────
    //  Strategy Views
    // ──────────────────────────────────────────────

    /**
     * @notice Get the strategy layer data of an NFA.
     * @param nfaId The NFA to query.
     * @return modelId The AI model identifier.
     * @return strategyHash The keccak256 hash of the strategy JSON.
     * @return strategyURI The IPFS/HTTPS link to the strategy JSON.
     */
    function getStrategy(uint256 nfaId) external view returns (
        string memory modelId,
        bytes32 strategyHash,
        string memory strategyURI
    ) {
        _requireOwned(nfaId);
        NFAData storage nfa = nfas[nfaId];
        return (nfa.modelId, nfa.strategyHash, nfa.strategyURI);
    }

    /**
     * @notice Verify that a full strategy JSON matches the stored strategyHash.
     * @param nfaId The NFA to verify.
     * @param fullStrategyJSON The full strategy JSON string to hash and compare.
     * @return True if the hash matches.
     */
    function verifyStrategy(
        uint256 nfaId,
        string calldata fullStrategyJSON
    ) external view returns (bool) {
        _requireOwned(nfaId);
        return keccak256(abi.encodePacked(fullStrategyJSON)) == nfas[nfaId].strategyHash;
    }

    /**
     * @notice Get all NFA token IDs that use a given strategy.
     * @param strategyHash The strategy hash to look up.
     * @return tokenIds Array of NFA token IDs using this strategy.
     */
    function getNFAsByStrategy(bytes32 strategyHash) external view returns (uint256[] memory) {
        return strategyNFAs[strategyHash];
    }

    /**
     * @notice Get battle stats for an NFA.
     */
    function getBattleStats(uint256 nfaId) external view returns (BattleStats memory) {
        _requireOwned(nfaId);
        return nfas[nfaId].stats;
    }

    /**
     * @notice Get the current listing for an NFA.
     */
    function getListing(uint256 nfaId) external view returns (Listing memory) {
        return listings[nfaId];
    }

    /**
     * @notice Get total number of NFAs minted.
     */
    function totalSupply() external view returns (uint256) {
        return _nextTokenId;
    }

    // ──────────────────────────────────────────────
    //  Admin Functions
    // ──────────────────────────────────────────────

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
    }

    function setBattleResolver(address _battleResolver) external onlyOwner {
        if (_battleResolver == address(0)) revert ZeroAddress();
        battleResolver = _battleResolver;
    }

    function setPlatformFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "Fee too high"); // max 10%
        platformFeeBps = _feeBps;
    }

    function setCreatorRoyaltyBps(uint256 _royaltyBps) external onlyOwner {
        require(_royaltyBps <= 1000, "Royalty too high"); // max 10%
        creatorRoyaltyBps = _royaltyBps;
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

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ──────────────────────────────────────────────
    //  Overrides (ERC721 + ERC721URIStorage)
    // ──────────────────────────────────────────────

    function tokenURI(
        uint256 tokenId
    ) public view override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC721, ERC721URIStorage) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    // ──────────────────────────────────────────────
    //  Internal Utilities
    // ──────────────────────────────────────────────

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
