import { ethers } from "hardhat";

import {
  RangeProtocolVault,
  RangeProtocolFactory,
  MockERC20,
} from "../typechain";
import { getInitializeData, setStorageAt } from "./common";

export const setupGHO: any = async ({
  managerAddress,
  vaultName,
  vaultSymbol,
  poolFee,
  ammFactoryAddress,
  collateralAddress,
  collateralATokenAddress,
  ghoAddress,
  ghoDebtAddress,
  poolAddressesProvider,
  collateralTokenPriceFeed,
  ghoPriceFeed,
}: {
  managerAddress: string;
  vaultName: string;
  vaultSymbol: string;
  poolFee: number;
  ammFactoryAddress: string;
  collateralAddress: string;
  collateralATokenAddress: string;
  ghoAddress: string;
  ghoDebtAddress: string;
  poolAddressesProvider: string;
  collateralTokenPriceFeed: string;
  ghoPriceFeed: string;
}) => {
  const RangeFactory = await ethers.getContractFactory("RangeProtocolFactory");
  const rangeFactory = (await RangeFactory.deploy(
    ammFactoryAddress
  )) as RangeProtocolFactory;

  const gho = (await ethers.getContractAt(
    "MockERC20",
    ghoAddress
  )) as MockERC20;
  const collateral = (await ethers.getContractAt(
    "MockERC20",
    collateralAddress
  )) as MockERC20;

  const ghoDebt = (await ethers.getContractAt(
    "MockERC20",
    ghoDebtAddress
  )) as MockERC20;
  const collateralAToken = (await ethers.getContractAt(
    "MockERC20",
    collateralATokenAddress
  )) as MockERC20;

  const LOGIC_LIB = await ethers.getContractFactory("LogicLib");
  const logicLib = await LOGIC_LIB.deploy();
  const RangeVault = await ethers.getContractFactory("RangeProtocolVault", {
    libraries: {
      LogicLib: logicLib.address,
    },
  });

  const vaultImpl = (await RangeVault.deploy()) as RangeProtocolVault;

  const initializeData = getInitializeData({
    managerAddress,
    name: vaultName,
    symbol: vaultSymbol,
    gho: ghoAddress,
    poolAddressesProvider,
    collateralTokenPriceFeed,
    ghoPriceFeed,
  });

  await rangeFactory.createVault(
    collateralAddress,
    poolFee,
    vaultImpl.address,
    initializeData
  );
  const vaultAddress = await rangeFactory.getVaultAddresses(0, 0);
  const vault = (await ethers.getContractAt(
    "RangeProtocolVault",
    vaultAddress[0]
  )) as RangeProtocolVault;

  await setStorageAt(
    collateralAddress,
    ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["address", "uint256"],
        [managerAddress, 9]
      )
    ),
    ethers.utils.hexlify(ethers.utils.zeroPad("0x54B40B1F852BDA000000", 32))
  );

  return {
    gho,
    ghoDebt,
    collateral,
    collateralAToken,
    vault,
  };
};
