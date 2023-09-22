import { ethers } from "hardhat";
import { expect } from "chai";
import { Decimal } from "decimal.js";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/dist/src/signer-with-address";
import {
  IERC20,
  IUniswapV3Factory,
  IUniswapV3Pool,
  RangeProtocolVault,
  RangeProtocolFactory,
  LogicLib,
} from "../typechain";
import {
  bn,
  encodePriceSqrt,
  getInitializeData,
  parseEther,
  position,
  setStorageAt,
} from "./common";
import { before, beforeEach } from "mocha";
import { BigNumber } from "ethers";

let factory: RangeProtocolFactory;
let vaultImpl: RangeProtocolVault;
let vault: RangeProtocolVault;
let logicLib: LogicLib;
let uniV3Factory: IUniswapV3Factory;
let univ3Pool: IUniswapV3Pool;
let token0: IERC20;
let token1: IERC20;
let manager: SignerWithAddress;
let nonManager: SignerWithAddress;
let newManager: SignerWithAddress;
let user2: SignerWithAddress;
const poolFee = 500;
const name = "Test Token";
const symbol = "TT";
const collateralAmount: BigNumber = ethers.utils.parseUnits("1000", 6);
let initializeData: any;
const lowerTick = -276420;
const upperTick = -276180;
const GHO = "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f";
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const MAX_UINT256 =
  "115792089237316195423570985008687907853269984665640564039457584007913129639935";

describe("RangeProtocolVault", () => {
  before(async () => {
    [manager, nonManager, user2, newManager] = await ethers.getSigners();
    uniV3Factory = await ethers.getContractAt(
      "IUniswapV3Factory",
      "0x1F98431c8aD98523631AE4a59f267346ea31F984"
    );

    const RangeProtocolFactory = await ethers.getContractFactory(
      "RangeProtocolFactory"
    );
    factory = (await RangeProtocolFactory.deploy(
      uniV3Factory.address
    )) as RangeProtocolFactory;

    token0 = await ethers.getContractAt("MockERC20", GHO);
    token1 = await ethers.getContractAt("MockERC20", USDC);

    univ3Pool = (await ethers.getContractAt(
      "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol:IUniswapV3Pool",
      await uniV3Factory.getPool(token0.address, token1.address, poolFee)
    )) as IUniswapV3Pool;

    initializeData = getInitializeData({
      managerAddress: manager.address,
      name,
      symbol,
      gho: "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f",
      poolAddressesProvider: "0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e",
      collateralTokenPriceFeed: "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6",
      collateralPriceOracleHeartbeat: 86400,
      ghoPriceFeed: "0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC",
      ghoPriceOracleHeartbeat: 86400,
    });

    const LogicLib = await ethers.getContractFactory("LogicLib");
    logicLib = await LogicLib.deploy();

    const RangeProtocolVault = await ethers.getContractFactory(
      "RangeProtocolVault",
      {
        libraries: {
          LogicLib: logicLib.address,
        },
      }
    );
    vaultImpl = (await RangeProtocolVault.deploy()) as RangeProtocolVault;

    await factory.createVault(
      token1.address,
      poolFee,
      vaultImpl.address,
      initializeData
    );

    const vaultAddress = await factory.getVaultAddresses(0, 0);
    vault = (await ethers.getContractAt(
      "RangeProtocolVault",
      vaultAddress[0]
    )) as RangeProtocolVault;
  });

  before(async () => {
    const usdcAmount = ethers.utils.hexlify(
      ethers.utils.zeroPad("0x5AF3107A4000", 32)
    );
    await setStorageAt(
      USDC,
      "0xcb8911fb82c2d10f6cf1d31d1e521ad3f4e3f42615f6ba67c454a9a2fdb9b6a7",
      usdcAmount
    );

    const ghoAmount = ethers.utils.hexlify(
      ethers.utils.zeroPad("0x52B7D2DCC80CD2E4000000", 32)
    );
    await setStorageAt(
      GHO,
      "0xc651ee22c6951bb8b5bd29e8210fb394645a94315fe10eff2cc73de1aa75c137",
      ghoAmount
    );

    // console.log((await token0.balanceOf(manager.address)).toString());
    // console.log((await token1.balanceOf(manager.address)).toString());
  });

  beforeEach(async () => {
    await token1.approve(vault.address, collateralAmount.mul(bn(2)));
  });

  it("should not allow minting with zero mint amount", async () => {
    const mintAmount = 0;
    await expect(vault.mint(mintAmount)).to.be.revertedWithCustomError(
      logicLib,
      "InvalidCollateralAmount"
    );
  });

  it("should not mint when contract is paused", async () => {
    expect(await vault.paused()).to.be.equal(false);
    await expect(vault.pause())
      .to.emit(vault, "Paused")
      .withArgs(manager.address);
    expect(await vault.paused()).to.be.equal(true);

    await expect(vault.mint(123)).to.be.revertedWith("Pausable: paused");
    await expect(vault.unpause())
      .to.emit(vault, "Unpaused")
      .withArgs(manager.address);
  });

  it("should mint with zero totalSupply of vault shares", async () => {
    expect(await vault.totalSupply()).to.be.equal(0);

    await expect(vault.mint(collateralAmount))
      .to.emit(vault, "Minted")
      .withArgs(manager.address, collateralAmount, collateralAmount);

    expect(await vault.totalSupply()).to.be.equal(collateralAmount);

    const { token, exists } = await vault.userVaults(manager.address);
    expect(exists).to.be.true;
    expect(token).to.be.equal(collateralAmount);
    const userVault = (await vault.getUserVaults(0, 0))[0];
    expect(userVault.user).to.be.equal(manager.address);
    expect(userVault.token).to.be.equal(collateralAmount);
    expect(await vault.userCount()).to.be.equal(1);
  });

  it("should mint with non zero totalSupply", async () => {
    const totalSupply = await vault.totalSupply();
    expect(totalSupply).to.not.be.equal(0);
    const shares = collateralAmount
      .mul(totalSupply)
      .div(await vault.getBalanceInCollateralToken());

    await expect(vault.mint(collateralAmount))
      .to.emit(vault, "Minted")
      .withArgs(manager.address, shares, collateralAmount);

    const { token } = await vault.userVaults(manager.address);
    expect(token).to.be.equal(collateralAmount.mul(bn(2)));
    expect(await vault.userCount()).to.be.equal(1);
  });

  it("only vault should be allowed to call mintShares from LogicLib", async () => {
    await expect(
      vault.mintShares(manager.address, 1)
    ).to.be.revertedWithCustomError(vault, "OnlyVaultAllowed");
  });

  it("should transfer vault shares to user2", async () => {
    const userBalance = await vault.balanceOf(manager.address);
    const transferAmount = collateralAmount.div(2);

    const { token: tokenUser0 } = await vault.userVaults(manager.address);

    const vaultMoved = tokenUser0.sub(
      tokenUser0.mul(userBalance.sub(transferAmount)).div(userBalance)
    );
    await vault.transfer(user2.address, transferAmount);

    const { token: tokenUser1Before } = await vault.userVaults(user2.address);
    expect(await vault.userCount()).to.be.equal(2);

    expect(tokenUser1Before).to.be.equal(vaultMoved);
    const user2Balance = await vault.balanceOf(user2.address);
    await vault.connect(user2).transfer(manager.address, user2Balance);

    const { token: tokenUser1After } = await vault.userVaults(user2.address);
    expect(tokenUser1After).to.be.equal(bn(0));
  });

  it("should not burn non existing vault shares", async () => {
    const burnAmount = 1;
    await expect(vault.connect(user2).burn(burnAmount)).to.be.revertedWith(
      "ERC20: burn amount exceeds balance"
    );
  });

  it("should burn vault shares", async () => {
    const burnAmount = await vault.balanceOf(manager.address);
    const amount = await vault.getBalanceInCollateralToken();
    const userBalance1Before = await token1.balanceOf(manager.address);
    await vault.updateFees(50, 250);

    const managingFee = await vault.managingFee();
    const totalSupply = await vault.totalSupply();
    const vaultShares = await vault.balanceOf(manager.address);
    const userBalance = amount.mul(vaultShares).div(totalSupply);
    const managingFeeAmount1 = userBalance.mul(managingFee).div(10_000);

    await vault.burn(burnAmount);
    expect(await vault.totalSupply()).to.be.equal(totalSupply.sub(burnAmount));

    expect(await token1.balanceOf(manager.address)).to.be.equal(
      userBalance1Before.add(userBalance).sub(managingFeeAmount1)
    );
    const { token: userVaultTokenAfter } = await vault.userVaults(
      manager.address
    );
    expect(userVaultTokenAfter).to.be.equal(bn(0));
    expect(await vault.managerBalance()).to.be.equal(managingFeeAmount1);
  });

  it("should mint and burn", async () => {
    const collateralInVault = (await token1.balanceOf(vault.address)).add(
      collateralAmount
    );
    await vault.mint(collateralAmount);
    expect(await vault.getBalanceInCollateralToken()).to.be.equal(
      collateralAmount
    );
    expect(await token0.balanceOf(vault.address)).to.be.equal(0);
    expect(await token1.balanceOf(vault.address)).to.be.equal(
      collateralInVault
    );

    const burnAmount = await vault.balanceOf(manager.address);
    await vault.burn(burnAmount);
    expect(await vault.getBalanceInCollateralToken()).to.be.equal(
      await vault.managerBalance()
    );
    expect(await token0.balanceOf(vault.address)).to.be.equal(0);
    expect(await token1.balanceOf(vault.address)).to.be.equal(
      await vault.managerBalance()
    );
  });

  it("only vault should be allowed to call burnShares from LogicLib", async () => {
    await expect(
      vault.burnShares(manager.address, 1)
    ).to.be.revertedWithCustomError(vault, "OnlyVaultAllowed");
  });

  describe("Manager Fee", () => {
    it("should not update managing and performance fee by non manager", async () => {
      await expect(
        vault.connect(nonManager).updateFees(100, 1000)
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should not update managing fee above BPS", async () => {
      await expect(vault.updateFees(101, 100)).to.be.revertedWithCustomError(
        logicLib,
        "InvalidManagingFee"
      );
    });

    it("should not update performance fee above BPS", async () => {
      await expect(vault.updateFees(100, 10001)).to.be.revertedWithCustomError(
        logicLib,
        "InvalidPerformanceFee"
      );
    });

    it("should update manager and performance fee by manager", async () => {
      await expect(vault.updateFees(100, 300))
        .to.emit(vault, "FeesUpdated")
        .withArgs(100, 300);
    });
  });

  describe("Update Price Oracles Heartbeat", async () => {
    it("non-manager should not be able to update heartbeat for price oracles", async () => {
      await expect(
        vault.connect(nonManager).updatePriceOracleHeartbeatsDuration(1, 1)
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("manager should be able to update ticks", async () => {
      const newCollateralPriceOracleHeartbeat = 86400 + 1;
      const newGhoPriceOracleHeartbeat = 86400 + 1;
      await expect(
        vault.updatePriceOracleHeartbeatsDuration(
          newCollateralPriceOracleHeartbeat,
          newGhoPriceOracleHeartbeat
        )
      )
        .to.emit(vault, "OraclesHeartbeatUpdated")
        .withArgs(
          newCollateralPriceOracleHeartbeat,
          newGhoPriceOracleHeartbeat
        );
    });
  });

  describe("Supply Collateral and Mint GHO", () => {
    it("non-manager should not be able to supply collateral", async () => {
      const collateralTokenInVault = await token1.balanceOf(vault.address);
      const collateralToProvide = collateralTokenInVault.mul(60).div(100);
      await expect(
        vault.connect(nonManager).supplyCollateral(collateralToProvide)
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("supply collateral", async () => {
      await token1.approve(vault.address, collateralAmount.mul(bn(10)));
      await vault.mint(collateralAmount);

      let { totalCollateralBase } = await vault.getAavePositionData();
      expect(totalCollateralBase).to.be.equal(0);

      const collateralTokenInVault = await token1.balanceOf(vault.address);
      const collateralToProvide = collateralTokenInVault.mul(60).div(100);
      await vault.supplyCollateral(collateralToProvide);

      ({ totalCollateralBase } = await vault.getAavePositionData());
      expect(totalCollateralBase).to.not.be.equal(0);
    });

    it("non-manager should not be able to mint gho", async () => {
      const ghoAmountToMint = ethers.utils.parseUnits("300", 18);
      await expect(
        vault.connect(nonManager).mintGHO(ghoAmountToMint)
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("Mint GHO", async () => {
      // eslint-disable-next-line prefer-const
      let { totalCollateralBase, totalDebtBase } =
        await vault.getAavePositionData();
      expect(totalCollateralBase).to.not.be.equal(0);
      expect(totalDebtBase).to.be.equal(0);

      const ghoAmountToMint = ethers.utils.parseUnits("300", 18);
      await vault.mintGHO(ghoAmountToMint);

      ({ totalDebtBase } = await vault.getAavePositionData());
      expect(totalDebtBase).to.not.be.equal(0);
    });
  });

  describe("Add Liquidity", () => {
    it("should not add liquidity by non-manager", async () => {
      const amount0 = await token0.balanceOf(vault.address);
      const collateralAmount = await token1.balanceOf(vault.address);

      await expect(
        vault
          .connect(nonManager)
          .addLiquidity(lowerTick, upperTick, amount0, collateralAmount, [0, 0])
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should add liquidity by manager", async () => {
      const ghoVaultAmount = await token0.balanceOf(vault.address);
      const collateralVaultAmount = await token1.balanceOf(vault.address);
      // eslint-disable-next-line @typescript-eslint/naming-convention
      const MockLiquidityAmounts = await ethers.getContractFactory(
        "MockLiquidityAmounts"
      );
      const mockLiquidityAmounts = await MockLiquidityAmounts.deploy();

      const { sqrtPriceX96 } = await univ3Pool.slot0();
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
        ghoVaultAmount,
        collateralVaultAmount
      );
      const { amount0: amount0ToAdd, amount1: amount1ToAdd } =
        await mockLiquidityAmounts.getAmountsForLiquidity(
          sqrtPriceX96,
          sqrtPriceA,
          sqrtPriceB,
          liquidityToAdd
        );
      await expect(
        await vault.addLiquidity(
          lowerTick,
          upperTick,
          amount0ToAdd,
          amount1ToAdd,
          [amount0ToAdd.mul(9900).div(10000), amount1ToAdd.mul(9900).div(10000)]
        )
      )
        .to.emit(vault, "LiquidityAdded")
        .withArgs(anyValue, lowerTick, upperTick, anyValue, anyValue);
    });
  });

  describe("Remove Liquidity", () => {
    it("should not remove liquidity by non-manager", async () => {
      await expect(
        vault.connect(nonManager).removeLiquidity()
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should remove liquidity by manager", async () => {
      expect(await vault.lowerTick()).to.not.be.equal(await vault.upperTick());
      expect(await vault.inThePosition()).to.be.equal(true);
      const { _liquidity: liquidityBefore } = await univ3Pool.positions(
        position(vault.address, lowerTick, upperTick)
      );
      expect(liquidityBefore).not.to.be.equal(0);

      const { fee0, fee1 } = await vault.getCurrentFees();
      await expect(vault.removeLiquidity())
        .to.emit(vault, "InThePositionStatusSet")
        .withArgs(false)
        .to.emit(vault, "FeesEarned")
        .withArgs(fee0, fee1);

      const { _liquidity: liquidityAfter } = await univ3Pool.positions(
        position(vault.address, lowerTick, upperTick)
      );
      expect(liquidityAfter).to.be.equal(0);
    });
  });

  describe("Burn GHO and Withdraw Collateral", async () => {
    it("non-manager should not be able to burn gho", async () => {
      await expect(
        vault.connect(nonManager).burnGHO(bn(MAX_UINT256))
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("Burn GHO", async () => {
      // eslint-disable-next-line prefer-const
      let { totalDebtBase } = await vault.getAavePositionData();
      expect(totalDebtBase).to.not.be.equal(0);

      const ghoVaultAmount = await token0.balanceOf(vault.address);
      const ghoDeficit = totalDebtBase
        .mul(bn(10).pow(18))
        .div(bn(10).pow(8))
        .sub(ghoVaultAmount)
        .add(bn(10).pow(bn(12)));

      await vault.swap(
        false,
        -ghoDeficit,
        bn("1461446703485210103287273052203988822378723970341"),
        ghoDeficit
      );
      await vault.burnGHO(bn(MAX_UINT256));

      ({ totalDebtBase } = await vault.getAavePositionData());
      expect(totalDebtBase).to.be.equal(0);
    });

    it("non-manager should not be able to withdraw collateral", async () => {
      await expect(
        vault.connect(nonManager).withdrawCollateral(bn(MAX_UINT256))
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("Withdraw Collateral", async () => {
      let { totalCollateralBase } = await vault.getAavePositionData();
      expect(totalCollateralBase).to.not.be.equal(0);
      await vault.withdrawCollateral(bn(MAX_UINT256));

      ({ totalCollateralBase } = await vault.getAavePositionData());
      expect(totalCollateralBase).to.be.equal(0);
    });
  });

  describe("empty the vault by burning shares", () => {
    it("should burn vault shares when liquidity is removed", async () => {
      const userBalance1Before = await token1.balanceOf(manager.address);
      await vault.swap(
        true,
        await token0.balanceOf(vault.address),
        bn("4295128740"),
        0
      );
      const amountCurrent = await vault.getBalanceInCollateralToken();
      const totalSupply = await vault.totalSupply();
      const vaultShares = await vault.balanceOf(manager.address);
      const managingFee = await vault.managingFee();
      const userBalance = amountCurrent.mul(vaultShares).div(totalSupply);
      const managingFeeAmount = userBalance.mul(managingFee).div(10_000);
      // console.log(
      //   userBalance.toString(),
      //   (await token1.balanceOf(vault.address)).toString()
      // );
      await expect(vault.burn(vaultShares)).not.to.emit(vault, "FeesEarned");
      expect(await token1.balanceOf(manager.address)).to.be.equal(
        userBalance1Before.add(userBalance).sub(managingFeeAmount)
      );

      // console.log((await token0.balanceOf(vault.address)).toString());
      // console.log((await token1.balanceOf(vault.address)).toString());
    });
  });

  describe("Fee collection", () => {
    before(async () => {
      await token1.approve(vault.address, collateralAmount);
      await vault.mint(collateralAmount);
      await vault.supplyCollateral(collateralAmount.div(2));
      await vault.mintGHO(collateralAmount.div(4));
      const ghoInVault = await token0.balanceOf(vault.address);
      const collateralInVault = await token1.balanceOf(vault.address);
      // eslint-disable-next-line @typescript-eslint/naming-convention
      const MockLiquidityAmounts = await ethers.getContractFactory(
        "MockLiquidityAmounts"
      );
      const mockLiquidityAmounts = await MockLiquidityAmounts.deploy();

      const { sqrtPriceX96 } = await univ3Pool.slot0();
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
        await token0.balanceOf(vault.address),
        await token1.balanceOf(vault.address)
      );
      const { amount0: amount0ToAdd, amount1: amount1ToAdd } =
        await mockLiquidityAmounts.getAmountsForLiquidity(
          sqrtPriceX96,
          sqrtPriceA,
          sqrtPriceB,
          liquidityToAdd
        );

      await vault.addLiquidity(
        lowerTick,
        upperTick,
        amount0ToAdd,
        amount1ToAdd,
        [amount0ToAdd.mul(9900).div(10000), amount1ToAdd.mul(9900).div(10000)]
      );

      const liquidity = await univ3Pool.liquidity();
      await token1.transfer(vault.address, collateralAmount);
      const priceNext = collateralAmount.mul(bn(2).pow(96)).div(liquidity);
      await vault.swap(false, collateralAmount, sqrtPriceX96.add(priceNext), 0);
    });

    it("non-manager should not collect fee", async () => {
      await expect(
        vault.connect(nonManager).collectManager()
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should manager collect fee", async () => {
      const { fee0, fee1 } = await vault.getCurrentFees();
      await expect(vault.pullFeeFromPool())
        .to.emit(vault, "FeesEarned")
        .withArgs(fee0, fee1);

      const managerTokenBalanceBefore = await token1.balanceOf(manager.address);
      const managerBalance = await vault.managerBalance();
      await vault.collectManager();
      expect(await token1.balanceOf(manager.address)).to.be.equal(
        managerTokenBalanceBefore.add(managerBalance)
      );
    });
  });

  describe("Test Upgradeability", () => {
    it("should not upgrade range vault implementation by non-manager of factory", async () => {
      // eslint-disable-next-line @typescript-eslint/naming-convention
      const RangeProtocolVault = await ethers.getContractFactory(
        "RangeProtocolVault",
        {
          libraries: {
            LogicLib: logicLib.address,
          },
        }
      );
      const newVaultImpl =
        (await RangeProtocolVault.deploy()) as RangeProtocolVault;

      await expect(
        factory
          .connect(nonManager)
          .upgradeVault(vault.address, newVaultImpl.address)
      ).to.be.revertedWith("Ownable: caller is not the owner");

      await expect(
        factory
          .connect(nonManager)
          .upgradeVaults([vault.address], [newVaultImpl.address])
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("should upgrade range vault implementation by factory manager", async () => {
      // eslint-disable-next-line @typescript-eslint/naming-convention
      const RangeProtocolVault = await ethers.getContractFactory(
        "RangeProtocolVault",
        {
          libraries: {
            LogicLib: logicLib.address,
          },
        }
      );
      const newVaultImpl =
        (await RangeProtocolVault.deploy()) as RangeProtocolVault;

      const implSlot = await vaultImpl.proxiableUUID();
      expect(
        await ethers.provider.getStorageAt(vault.address, implSlot)
      ).to.be.equal(
        ethers.utils.hexZeroPad(vaultImpl.address.toLowerCase(), 32)
      );
      await expect(factory.upgradeVault(vault.address, newVaultImpl.address))
        .to.emit(factory, "VaultImplUpgraded")
        .withArgs(vault.address, newVaultImpl.address);

      expect(
        await ethers.provider.getStorageAt(vault.address, implSlot)
      ).to.be.equal(
        ethers.utils.hexZeroPad(newVaultImpl.address.toLowerCase(), 32)
      );

      const newVaultImpl1 =
        (await RangeProtocolVault.deploy()) as RangeProtocolVault;

      expect(
        await ethers.provider.getStorageAt(vault.address, implSlot)
      ).to.be.equal(
        ethers.utils.hexZeroPad(newVaultImpl.address.toLowerCase(), 32)
      );
      await expect(
        factory.upgradeVaults([vault.address], [newVaultImpl1.address])
      )
        .to.emit(factory, "VaultImplUpgraded")
        .withArgs(vault.address, newVaultImpl1.address);

      expect(
        await ethers.provider.getStorageAt(vault.address, implSlot)
      ).to.be.equal(
        ethers.utils.hexZeroPad(newVaultImpl1.address.toLowerCase(), 32)
      );

      vaultImpl = newVaultImpl1;
    });
  });

  describe("transferOwnership", () => {
    it("should not be able to transferOwnership by non manager", async () => {
      await expect(
        vault.connect(nonManager).transferOwnership(newManager.address)
      ).to.be.revertedWith("Ownable: caller is not the manager");
    });

    it("should be able to transferOwnership by manager", async () => {
      await expect(vault.transferOwnership(newManager.address))
        .to.emit(vault, "OwnershipTransferred")
        .withArgs(manager.address, newManager.address);
      expect(await vault.manager()).to.be.equal(newManager.address);

      await vault.connect(newManager).transferOwnership(manager.address);
      expect(await vault.manager()).to.be.equal(manager.address);
    });
  });
});
