import { ethers } from "hardhat";
import { LedgerSigner } from "@anders-t/ethers-ledger";
import { getInitializeData } from "../test/common";

async function main() {
  const provider = ethers.getDefaultProvider(""); // To be updated.
  const ledger = await new LedgerSigner(provider, ""); // To be updated.
  const managerAddress = ""; // To be updated.
  const rangeProtocolFactoryAddress = ""; // To be updated.
  const vaultImplAddress = ""; // to be updated.
  const token0 = "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f"; // to be updated.
  const token1 = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // to be updated.
  const fee = 500;
  const name = ""; // To be updated.
  const symbol = ""; // To be updated.

  let factory = await ethers.getContractAt(
    "RangeProtocolFactory",
    rangeProtocolFactoryAddress
  );
  factory = await factory.connect(ledger);
  const data = getInitializeData({
    managerAddress,
    name,
    symbol,
    gho: token0,
    poolAddressesProvider: "0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e",
    collateralTokenPriceFeed: "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6",
    collateralPriceOracleHeartbeat: 86400,
    ghoPriceFeed: "0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC",
    ghoPriceOracleHeartbeat: 86400,
  });

  const tx = await factory.createVault(token1, fee, vaultImplAddress, data);
  const txReceipt = await tx.wait();
  const [
    {
      args: { vault },
    },
  ] = txReceipt.events.filter(
    (event: { event: any }) => event.event === "VaultCreated"
  );
  console.log("Vault: ", vault);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
