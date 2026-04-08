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
├── GemBotsNFAv5.sol           # Active NFA contract (ERC-721 + ERC-8004)
├── GemBotsGenesisVault.sol    # Genesis wrapper for revenue share / voting / staking
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

## Genesis Wrapper: GemBotsGenesisVault

`GemBotsGenesisVault.sol` is a standalone wrapper contract layered on top of the live GemBotsNFAv5 collection at
[`0x9bC5f392cE8C7aA13BD5bC7D5A1A12A4DD58b3D5`](https://bscscan.com/address/0x9bC5f392cE8C7aA13BD5bC7D5A1A12A4DD58b3D5).
It does **not** modify the original NFT contract.

### What it adds

- **Immutable Genesis detection** — token IDs `1..100` are treated as Genesis forever
- **Revenue share vault** — accepts BNB platform fees and lets Genesis holders claim their share
- **Tier override helper** — `isGenesisDiamond(tokenId)` returns `true` for Genesis tokens
- **Governance weight helper** — `getVotingWeight(tokenId)` returns `10` for Genesis and `1` for regular Diamond lookups
- **Optional staking** — `stake(tokenId)` / `unstake(tokenId)` enable boosted revenue-share weight for Genesis holders

### Design notes

- Reads ownership from the main NFT contract via `ownerOf(tokenId)`
- Uses `Ownable` for admin controls and `ReentrancyGuard` for ETH safety
- Keeps all Genesis privilege logic isolated in the wrapper so the production NFT contract remains unchanged
- Revenue distribution is claim-based rather than push-based, so holders can withdraw when convenient

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

## Scripts

### Update tier mint fees (preview only)

A dry-run helper script is available at:

- `scripts/update-tier-fees.js`

What it does:
- connects to BSC mainnet
- reads current `tierMintFees`
- prints current vs target values
- prepares calldata / populated owner transaction requests
- **does not broadcast any transaction**

Example:

```bash
BSC_RPC_URL=https://bsc-dataseed.binance.org/ node scripts/update-tier-fees.js
```

Optional owner preview:

```bash
BSC_RPC_URL=https://bsc-dataseed.binance.org/ \
DEPLOYER_PRIVATE_KEY=0xabc... \
node scripts/update-tier-fees.js
```

## License

MIT
