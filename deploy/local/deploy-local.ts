import { ethers } from "hardhat";
import {getInitializeData} from "../../test/common";
async function main() {
    const [signer] = await ethers.getSigners();
    const LogicLib = await ethers.getContractFactory("LogicLib");
    const logicLib = await LogicLib.deploy();
    console.log("logicLib: ", logicLib.address);

    const UNI_V3_FACTORY = "0x1F98431c8aD98523631AE4a59f267346ea31F984";
    const RangeProtocolFactory = await ethers.getContractFactory("RangeProtocolFactory");
    const factory = await RangeProtocolFactory.deploy(UNI_V3_FACTORY);
    console.log("Factory: ", factory.address);

    const RangeProtocolVault = await ethers.getContractFactory(
        "RangeProtocolVault",
        {
            libraries: {
                LogicLib: logicLib.address,
            },
        }
    );
    const vaultImpl = await RangeProtocolVault.deploy();
    console.log(vaultImpl.address);

    const token0 = "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f"; // to be updated.
    const token1 = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // to be updated.
    const fee = 3000; // To be updated.
    const name = "Test Token"; // To be updated.
    const symbol = "test token"; // To be updated.

    const data = getInitializeData({
        managerAddress: signer.address,
        name,
        symbol,
        gho: "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f",
        poolAddressesProvider: "0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e"
    });

    const tx = await factory.createVault(token1, fee, vaultImpl.address, data);
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
