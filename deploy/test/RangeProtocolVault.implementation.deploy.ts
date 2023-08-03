import { ethers } from "hardhat";

async function main() {
  const logicLib = "0xfB12F7170FF298CDed84C793dAb9aBBEcc01E798"; // to be updated.
  let RangeProtocolVault = await ethers.getContractFactory(
    "RangeProtocolVault",
    {
      libraries: {
        LogicLib: logicLib,
      },
    }
  );
  const vaultImpl = await RangeProtocolVault.deploy();
  console.log(vaultImpl.address);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
