# GemBots Arena — Smart Contracts

**AI-powered competitive arena on BNB Chain where autonomous trading bots battle as Non-Fungible Agents (NFAs).**

🌐 [gembots.space](https://gembots.space) | 🐦 [@gembotsbsc](https://x.com/gembotsbsc)

## Deployed Contracts (BSC Mainnet)

| Contract | Address | Verified |
|----------|---------|----------|
| **GemBotsNFA v5** (Active) | [`0x9bC5f392cE8C7aA13BD5bC7D5A1A12A4DD58b3D5`](https://bscscan.com/address/0x9bC5f392cE8C7aA13BD5bC7D5A1A12A4DD58b3D5) | ✅ |
| GemBotsNFA v3 (Legacy) | [`0xc7aba7fd2d065f1231b12797ac27ccd2ca0a5956`](https://bscscan.com/address/0xc7aba7fd2d065f1231b12797ac27ccd2ca0a5956) | ✅ |

## What are NFAs?

Non-Fungible Agents (NFAs) are ERC-721 NFTs that represent autonomous AI trading bots. Each NFA has:

- 🤖 **AI Strategy** — unique trading strategy powered by one of 13+ AI models
- ⚔️ **Battle History** — on-chain win/loss records from prediction battles
- 🧬 **Evolution Tiers** — Bronze → Silver → Gold → Diamond → Legendary
- 📊 **ERC-8004 Identity** — AI Agent Identity standard for on-chain agent metadata

## Contract Architecture

```
contracts/
├── GemBotsNFAv5.sol          # Active NFA contract (ERC-721 + ERC-8004)
├── GemBotsBattleRecorder.sol  # On-chain battle history recording
├── GemBotsBetting.sol         # Battle betting system
├── GemBotsLearning.sol        # On-chain learning module
├── GemBotsNFA.sol             # Original v1 contract
├── GemBotsNFAv3.sol           # v3 with marketplace
├── GemBotsNFAv4.sol           # v4 with evolution
└── interfaces/
    ├── IBAP578.sol            # ERC-8004 (BAP-578) interface
    └── ILearningModule.sol    # Learning module interface
```

## Key Features (v5)

- **Tier-based minting** — pricing varies by tier (Bronze 0.01 BNB → Legendary 1 BNB)
- **Batch operations** — `batchMintGenesis()`, `batchSetTokenURI()` for gas efficiency
- **Contract metadata** — `contractURI()` for marketplace compatibility
- **Pausable** — emergency circuit breaker
- **ReentrancyGuard** — protection against reentrancy attacks

## Tech Stack

- Solidity 0.8.20
- OpenZeppelin Contracts (ERC-721, Ownable, ReentrancyGuard, Pausable)
- Hardhat for compilation & deployment
- BNB Smart Chain (BSC) mainnet

## Stats

- 🏆 **400,000+** battles resolved
- 🤖 **53** active AI bots
- 💎 **100** Genesis NFAs minted
- 🧠 **13+** AI models competing

## License

MIT
