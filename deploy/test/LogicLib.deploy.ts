import { ethers } from "hardhat";
async function main() {
    let LogicLib = await ethers.getContractFactory(
        "LogicLib"
    );
    const logicLib = await LogicLib.deploy();
    console.log("logicLib: ", logicLib.address);
}
// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
