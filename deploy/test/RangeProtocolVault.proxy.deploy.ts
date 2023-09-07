import { ethers, network } from "hardhat";
import { getInitializeData } from "../../test/common";

async function main() {
  const managerAddress = "0x9F78223D10885bF1Cc0675631b4e2BE507049d5d"; // updated.
  const rangeProtocolFactoryAddress = "0xF266068C5c38Cd588035E13dE28aaB4f3bbEB8C5"; // To be updated.
  const vaultImplAddress = "0x98868965E1D4784944D0B9eeb81788fE027940C5"; // to be updated.
  const token0 = "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f"; // to be updated.
  const token1 = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // to be updated.
  const fee = 100; // To be updated.
  const name = "Range GHO Bootstrapping Vault - USDC"; // To be updated.
  const symbol = "rUSDC"; // To be updated.
  let factory = await ethers.getContractAt(
      "RangeProtocolFactory",
      rangeProtocolFactoryAddress
  );
  const data = getInitializeData({
    managerAddress,
    name,
    symbol,
    gho: "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f",
    poolAddressesProvider: "0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e",
    collateralTokenPriceFeed: "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6",
    ghoPriceFeed: "0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC",
  });
  // network.config.accounts = "remote";
  // await network.provider.send(
  //     'hardhat_impersonateAccount',
  //     ["0x27c1629B5435b2Ffe5709D22E0b530FC244CdE3e"] // copy your account address here
  // );
  //
  // // sign a transaction with your impersonated account
  // const signer = await ethers.provider.getSigner("0x27c1629B5435b2Ffe5709D22E0b530FC244CdE3e");
  const funcInterface = new ethers.utils.Interface([
      "function createVault( address token, uint24 fee, address implementation, bytes memory data ) external;"
  ])
  const funcData = funcInterface.encodeFunctionData("createVault", [
    token1, fee, vaultImplAddress, data
  ]);
  console.log(funcData);
  // const tx = await factory.createVault(token1, fee, vaultImplAddress, data);
  // const txReceipt = await tx.wait();
  // const [
  //   {
  //     args: { vault },
  //   },
  // ] = txReceipt.events.filter(
  //     (event: { event: any }) => event.event === "VaultCreated"
  // );
  // console.log("Vault: ", vault);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
