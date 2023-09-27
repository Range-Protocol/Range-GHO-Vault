import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import { IERC20, RangeProtocolVault } from "../typechain";
import { bn } from "./common";
import { setupGHO } from "./setup-gho";
import { Decimal } from "decimal.js";

let vault: RangeProtocolVault;
let gho: IERC20;
let collateral: IERC20;
let ghoDebt: IERC20;
let collateralAToken: IERC20;
let manager: SignerWithAddress;

const MAX_UINT = bn(
  "115792089237316195423570985008687907853269984665640564039457584007913129639935"
);

describe("Test suite for Aave", () => {
  before(async () => {
    const GHO = "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f";
    const ghoDebtAddress = "0x786dbff3f1292ae8f92ea68cf93c30b34b1ed04b";
    const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
    const aUSDC = "0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c";
    const poolAddressesProvider = "0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e";
    const collateralTokenPriceFeed =
      "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6";
    const ghoPriceFeed = "0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC";

    [manager] = await ethers.getSigners();
    ({ gho, collateral, ghoDebt, collateralAToken, vault } = await setupGHO({
      managerAddress: manager.address,
      vaultName: "Test Vault",
      vaultSymbol: "TV",
      poolFee: 500,
      ammFactoryAddress: "0x1F98431c8aD98523631AE4a59f267346ea31F984",
      collateralAddress: USDC,
      collateralATokenAddress: aUSDC,
      ghoAddress: GHO,
      ghoDebtAddress: ghoDebtAddress,
      poolAddressesProvider,
      collateralTokenPriceFeed,
      collateralPriceOracleHeartbeat: 86400,
      ghoPriceFeed,
      ghoPriceOracleHeartbeat: 86400,
    }));
  });

  it("Test suite", async () => {
    const usdcDepositAmount = ethers.utils.parseUnits("100000", 6);
    await collateral.approve(vault.address, usdcDepositAmount);
    await vault.mint(usdcDepositAmount, usdcDepositAmount);

    console.log(
      "User vault balance: ",
      (await vault.balanceOf(manager.address)).toString()
    );
    console.log(
      "Vault USDC balance: ",
      (await collateral.balanceOf(vault.address)).toString()
    );

    const supplyingCollateral = usdcDepositAmount.div(bn(2));
    await vault.supplyCollateral(supplyingCollateral);
    const ghoMintAmount = supplyingCollateral
      .mul(bn(10).pow(12))
      .mul(70)
      .div(100);
    await vault.mintGHO(ghoMintAmount);
    await vault.getBalanceInCollateralToken();
    console.log(
      "After supplying 50k usdc to aave as supply and borrowing 35k GHO"
    );
    console.log(
      "Vault USDC balance: ",
      (await collateral.balanceOf(vault.address)).toString()
    );
    console.log(
      "Vault GHO balance: ",
      (await gho.balanceOf(vault.address)).toString()
    );

    const lowerTick = -276480;
    const upperTick = -276300;

    const usdcBalance = await collateral.balanceOf(vault.address);
    const ghoBalance = await gho.balanceOf(vault.address);
    // eslint-disable-next-line @typescript-eslint/naming-convention
    const MockLiquidityAmounts = await ethers.getContractFactory(
      "MockLiquidityAmounts"
    );
    const mockLiquidityAmounts = await MockLiquidityAmounts.deploy();

    const pool = await ethers.getContractAt(
      "IUniswapV3Pool",
      await vault.pool()
    );
    const { sqrtPriceX96 } = await pool.slot0();
    const sqrtPriceA = new Decimal(1.0001)
      .pow(lowerTick)
      .sqrt()
      .mul(new Decimal(2).pow(96))
      .round()
      .toFixed();
    const sqrtPriceB = new Decimal(1.0001)
      .pow(upperTick)
      .sqrt()
      .mul(new Decimal(2).pow(96))
      .round()
      .toFixed();
    const liquidityToAdd = await mockLiquidityAmounts.getLiquidityForAmounts(
      sqrtPriceX96,
      sqrtPriceA,
      sqrtPriceB,
      ghoBalance,
      usdcBalance
    );
    const { amount0: ghoToAdd, amount1: usdcToAdd } =
      await mockLiquidityAmounts.getAmountsForLiquidity(
        sqrtPriceX96,
        sqrtPriceA,
        sqrtPriceB,
        liquidityToAdd
      );

    await vault.addLiquidity(lowerTick, upperTick, ghoToAdd, usdcToAdd, [
      ghoToAdd.mul(10100).div(10000),
      usdcToAdd.mul(10100).div(10000),
    ]);
    await vault.getBalanceInCollateralToken();

    console.log(
      "Vault balance after adding maximum liquidity to uniswap v3 0.3% pool"
    );
    console.log(
      "Vault USDC balance: ",
      (await collateral.balanceOf(vault.address)).toString()
    );
    console.log(
      "Vault GHO balance: ",
      (await gho.balanceOf(vault.address)).toString()
    );

    await vault.swap(
      false,
      ethers.utils.parseUnits("1000", 6),
      bn("146144670348521010328727305220398882237872397034"),
      0
    );
    console.log("Vault balance after swapping 1000 usdc to gho");
    console.log(
      "Vault USDC balance: ",
      (await collateral.balanceOf(vault.address)).toString()
    );
    console.log(
      "Vault GHO balance: ",
      (await gho.balanceOf(vault.address)).toString()
    );

    await vault.removeLiquidity([0, 0]);
    console.log("Vault balance after removing liquidity from uniswap");
    console.log(
      "Vault USDC balance: ",
      (await collateral.balanceOf(vault.address)).toString()
    );
    console.log(
      "Vault GHO balance: ",
      (await gho.balanceOf(vault.address)).toString()
    );

    let { totalCollateralBase, totalDebtBase } =
      await vault.getAavePositionData();
    await vault.burnGHO(MAX_UINT);
    console.log("Vault balance after paying back debt");
    console.log(
      "Vault USDC balance: ",
      (await collateral.balanceOf(vault.address)).toString()
    );
    console.log(
      "Vault GHO balance: ",
      (await gho.balanceOf(vault.address)).toString()
    );

    await vault.withdrawCollateral(MAX_UINT);
    console.log("Vault balance after withdrawing collateral");
    console.log(
      "Vault USDC balance: ",
      (await collateral.balanceOf(vault.address)).toString()
    );
    console.log(
      "Vault GHO balance: ",
      (await gho.balanceOf(vault.address)).toString()
    );
    ({ totalCollateralBase, totalDebtBase } =
      await vault.getAavePositionData());
    console.log(totalCollateralBase.toString(), totalDebtBase.toString());
    const _ghoBalance = await gho.balanceOf(vault.address);
    await vault.swap(true, _ghoBalance, 4295128740, 0);
    console.log(
      (await vault.getBalanceInCollateralToken()).toString(),
      (await vault.balanceOf(manager.address)).toString(),
      (await vault.totalSupply()).toString()
    );
    console.log((await vault.balanceOf(manager.address)).toString());
    await vault.burn(await vault.balanceOf(manager.address), 0);

    console.log((await vault.managerBalance()).toString());

    console.log("Vault balance after position is closed");
    console.log(
      "Vault USDC balance: ",
      (await collateral.balanceOf(vault.address)).toString()
    );
    console.log(
      "Vault GHO balance: ",
      (await gho.balanceOf(vault.address)).toString()
    );
  });
});
