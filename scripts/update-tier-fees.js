#!/usr/bin/env node
/* eslint-disable no-console */
try {
  require("dotenv").config();
} catch (_) {
  // Optional: environment variables can be provided directly via shell.
}
const { ethers } = require("ethers");

const CONTRACT_ADDRESS = "0x9bC5f392cE8C7aA13BD5bC7D5A1A12A4DD58b3D5";
const BSC_RPC_URL = process.env.BSC_RPC_URL || "https://bsc-dataseed.binance.org/";

const TIERS = [
  { name: "Bronze", enumValue: 0, wei: 100000000000000000n },
  { name: "Silver", enumValue: 1, wei: 300000000000000000n },
  { name: "Gold", enumValue: 2, wei: 750000000000000000n },
  { name: "Diamond", enumValue: 3, wei: 1500000000000000000n },
];

const ABI = [
  "function owner() view returns (address)",
  "function tierMintFees(uint8) view returns (uint256)",
  "function setTierMintFee(uint8,uint256)",
];

function formatBnb(value) {
  return `${ethers.formatEther(value)} BNB`;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(BSC_RPC_URL);
  const contract = new ethers.Contract(CONTRACT_ADDRESS, ABI, provider);

  console.log("GemBotsNFAv5 tier fee update preview");
  console.log("=================================");
  console.log(`RPC: ${BSC_RPC_URL}`);
  console.log(`Contract: ${CONTRACT_ADDRESS}`);
  console.log();

  const owner = await contract.owner();
  console.log(`On-chain owner: ${owner}`);
  console.log();

  console.log("Current vs new tier mint fees:");
  console.log("---------------------------------");

  for (const tier of TIERS) {
    const current = await contract.tierMintFees(tier.enumValue);
    console.log(
      `${tier.name.padEnd(8)} | current: ${current.toString().padEnd(20)} (${formatBnb(current)}) | new: ${tier.wei.toString().padEnd(20)} (${formatBnb(tier.wei)})`
    );
  }

  console.log();
  console.log("Prepared owner calls (not executed):");
  console.log("-----------------------------------");

  for (const tier of TIERS) {
    const calldata = contract.interface.encodeFunctionData("setTierMintFee", [tier.enumValue, tier.wei]);
    console.log(`setTierMintFee(${tier.enumValue}, ${tier.wei})  // ${tier.name}`);
    console.log(`calldata: ${calldata}`);
    console.log();
  }

  if (process.env.DEPLOYER_PRIVATE_KEY) {
    const wallet = new ethers.Wallet(process.env.DEPLOYER_PRIVATE_KEY, provider);
    console.log(`Loaded signer: ${wallet.address}`);
    console.log(`Signer matches owner: ${wallet.address.toLowerCase() === owner.toLowerCase()}`);
    console.log();
    console.log("Dry-run transaction request objects:");
    console.log("-----------------------------------");

    for (const tier of TIERS) {
      const txRequest = await contract.connect(wallet).setTierMintFee.populateTransaction(tier.enumValue, tier.wei);
      console.log(`${tier.name}:`);
      console.dir(txRequest, { depth: null });
      console.log();
    }
  } else {
    console.log("No DEPLOYER_PRIVATE_KEY provided. Skipping signer-bound populateTransaction preview.");
  }

  console.log("IMPORTANT: This script does NOT broadcast transactions.");
  console.log("To execute later, uncomment/send the populated txs manually or adapt this script in a separate ops step.");
}

main().catch((error) => {
  console.error("Script failed:");
  console.error(error);
  process.exit(1);
});
