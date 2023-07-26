//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {LiquidityAmounts} from "../uniswap/LiquidityAmounts.sol";
import {FullMath} from "../uniswap/FullMath.sol";
import {TickMath} from "../uniswap/TickMath.sol";
import {DataTypesLib} from "./DataTypesLib.sol";
import {IRangeProtocolVault} from "../interfaces/IRangeProtocolVault.sol";
import {IPriceOracleExtended} from "../interfaces/IPriceOracleExtended.sol";
import {VaultErrors} from "../errors/VaultErrors.sol";

library LogicLib {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using TickMath for int24;

    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 1000;
    uint16 public constant MAX_MANAGING_FEE_BPS = 100;

    event Minted(address indexed receiver, uint256 shares, uint256 amount);
    event Burned(address indexed receiver, uint256 burnAmount, uint256 amount);
    event LiquidityAdded(
        uint256 liquidityMinted,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0In,
        uint256 amount1In
    );
    event LiquidityRemoved(
        uint256 liquidityRemoved,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Out,
        uint256 amount1Out
    );
    event FeesEarned(uint256 feesEarned0, uint256 feesEarned1);
    event FeesUpdated(uint16 managingFee, uint16 performanceFee);
    event InThePositionStatusSet(bool inThePosition);
    event Swapped(bool zeroForOne, int256 amount0, int256 amount1);
    event TicksSet(int24 lowerTick, int24 upperTick);
    event CollateralSupplied(address token, uint256 amount);
    event CollateralWithdrawn(address token, uint256 amount);
    event GHOMinted(uint256 amount);
    event GHOBurned(uint256 amount);

    function updateTicks(DataTypesLib.PoolData storage poolData, int24 _lowerTick, int24 _upperTick) external {
        if (IRangeProtocolVault(address(this)).totalSupply() != 0 || poolData.inThePosition)
            revert VaultErrors.NotAllowedToUpdateTicks();
        _validateTicks(_lowerTick, _upperTick, poolData.tickSpacing);
        poolData.lowerTick = _lowerTick;
        poolData.upperTick = _upperTick;

        emit TicksSet(_lowerTick, _upperTick);
    }

    function uniswapV3MintCallback(
        DataTypesLib.PoolData storage poolData,
        uint256 amount0Owed,
        uint256 amount1Owed
    ) external {
        if (msg.sender != address(poolData.pool)) revert VaultErrors.OnlyPoolAllowed();
        if (amount0Owed > 0) poolData.token0.safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) poolData.token1.safeTransfer(msg.sender, amount1Owed);
    }

    function uniswapV3SwapCallback(
        DataTypesLib.PoolData storage poolData,
        int256 amount0Delta,
        int256 amount1Delta
    ) external {
        if (msg.sender != address(poolData.pool)) revert VaultErrors.OnlyPoolAllowed();
        if (amount0Delta > 0) poolData.token0.safeTransfer(msg.sender, uint256(amount0Delta));
        else if (amount1Delta > 0) poolData.token1.safeTransfer(msg.sender, uint256(amount1Delta));
    }

    function mint(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        DataTypesLib.UserData storage userData,
        DataTypesLib.AaveData storage aaveData,
        uint256 amount
    ) external returns (uint256 shares) {
        if (amount == 0) revert VaultErrors.InvalidCollateralAmount();
        IRangeProtocolVault vault = IRangeProtocolVault(address(this));
        uint256 totalSupply = vault.totalSupply();
        if (totalSupply != 0) {
            uint256 totalAmount = getUnderlyingBalance(poolData, feeData, aaveData);
            shares = FullMath.mulDivRoundingUp(amount, totalSupply, totalAmount);
        } else {
            shares = amount;
        }
        vault.mintShares(msg.sender, shares);
        if (!userData.vaults[msg.sender].exists) {
            userData.vaults[msg.sender].exists = true;
            userData.users.push(msg.sender);
        }
        userData.vaults[msg.sender].token += amount;
        aaveData.collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Minted(msg.sender, shares, amount);
    }

    function burn(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        DataTypesLib.UserData storage userData,
        DataTypesLib.AaveData storage aaveData,
        uint256 shares
    ) external returns (uint256 withdrawAmount) {
        if (shares == 0) revert VaultErrors.InvalidBurnAmount();
        IRangeProtocolVault vault = IRangeProtocolVault(address(this));
        uint256 totalSupply = vault.totalSupply();
        uint256 balanceBefore = vault.balanceOf(msg.sender);
        vault.burnShares(msg.sender, shares);

        uint256 totalAmount = getUnderlyingBalance(poolData, feeData, aaveData);
        withdrawAmount = FullMath.mulDiv(shares, totalAmount, totalSupply);
        _applyManagingFee(feeData, withdrawAmount);
        withdrawAmount = _netManagingFees(feeData, withdrawAmount);

        userData.vaults[msg.sender].token =
            (userData.vaults[msg.sender].token * (balanceBefore - shares)) /
            balanceBefore;
        aaveData.collateralToken.safeTransfer(msg.sender, withdrawAmount);
        emit Burned(msg.sender, shares, withdrawAmount);
    }

    function removeLiquidity(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        DataTypesLib.AaveData storage aaveData
    ) external {
        (uint128 liquidity, , , , ) = poolData.pool.positions(getPositionID(poolData));
        if (liquidity != 0) {
            (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1) = _withdraw(poolData, liquidity);
            emit LiquidityRemoved(liquidity, poolData.lowerTick, poolData.upperTick, amount0, amount1);

            _applyPerformanceFee(poolData, feeData, aaveData, fee0, fee1);
            (fee0, fee1) = _netPerformanceFees(feeData, fee0, fee1);
            emit FeesEarned(fee0, fee1);
        }

        poolData.lowerTick = poolData.upperTick;
        poolData.inThePosition = false;
        emit InThePositionStatusSet(false);
    }

    function swap(
        DataTypesLib.PoolData storage poolData,
        bool zeroForOne,
        int256 swapAmount,
        uint160 sqrtPriceLimitX96
    ) external returns (int256 amount0, int256 amount1) {
        (amount0, amount1) = poolData.pool.swap(address(this), zeroForOne, swapAmount, sqrtPriceLimitX96, "");
        emit Swapped(zeroForOne, amount0, amount1);
    }

    function addLiquidity(
        DataTypesLib.PoolData storage poolData,
        int24 newLowerTick,
        int24 newUpperTick,
        uint256 amount0,
        uint256 amount1
    ) external returns (uint256 remainingAmount0, uint256 remainingAmount1) {
        if (poolData.inThePosition) revert VaultErrors.LiquidityAlreadyAdded();
        _validateTicks(newLowerTick, newUpperTick, poolData.tickSpacing);
        (uint160 sqrtRatioX96, , , , , , ) = poolData.pool.slot0();
        uint128 baseLiquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtRatioX96,
            newLowerTick.getSqrtRatioAtTick(),
            newUpperTick.getSqrtRatioAtTick(),
            amount0,
            amount1
        );
        if (baseLiquidity > 0) {
            (uint256 amountDeposited0, uint256 amountDeposited1) = poolData.pool.mint(
                address(this),
                newLowerTick,
                newUpperTick,
                baseLiquidity,
                ""
            );
            emit LiquidityAdded(baseLiquidity, newLowerTick, newUpperTick, amountDeposited0, amountDeposited1);

            remainingAmount0 = amount0 - amountDeposited0;
            remainingAmount1 = amount1 - amountDeposited1;
            poolData.lowerTick = newLowerTick;
            poolData.upperTick = newUpperTick;
            emit TicksSet(newLowerTick, newUpperTick);

            poolData.inThePosition = true;
            emit InThePositionStatusSet(true);
        }
    }

    function pullFeeFromPool(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        DataTypesLib.AaveData storage aaveData
    ) external {
        (, , uint256 fee0, uint256 fee1) = _withdraw(poolData, 0);
        _applyPerformanceFee(poolData, feeData, aaveData, fee0, fee1);
        (fee0, fee1) = _netPerformanceFees(feeData, fee0, fee1);
        emit FeesEarned(fee0, fee1);
    }

    function collectManager(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        address manager
    ) external {
        uint256 ghoAmount = feeData.managerBalanceGHO;
        uint256 tokenAmount = feeData.managerBalanceToken;
        feeData.managerBalanceGHO = 0;
        feeData.managerBalanceToken = 0;

        (IERC20Upgradeable gho, IERC20Upgradeable token) = poolData.isToken0GHO
            ? (poolData.token0, poolData.token1)
            : (poolData.token1, poolData.token0);

        if (ghoAmount != 0) gho.safeTransfer(manager, ghoAmount);
        if (tokenAmount != 0) token.safeTransfer(manager, tokenAmount);
    }

    function updateFees(
        DataTypesLib.FeeData storage feeData,
        uint16 newManagingFee,
        uint16 newPerformanceFee
    ) external {
        if (newManagingFee > MAX_MANAGING_FEE_BPS) revert VaultErrors.InvalidManagingFee();
        if (newPerformanceFee > MAX_PERFORMANCE_FEE_BPS) revert VaultErrors.InvalidPerformanceFee();

        feeData.managingFee = newManagingFee;
        feeData.performanceFee = newPerformanceFee;
        emit FeesUpdated(newManagingFee, newPerformanceFee);
    }

    function supplyCollateral(DataTypesLib.AaveData storage aaveData, uint256 supplyAmount) external {
        IPool aavePool = IPool(aaveData.poolAddressesProvider.getPool());
        IERC20Upgradeable collateralToken = aaveData.collateralToken;
        collateralToken.approve(address(aavePool), supplyAmount);
        aavePool.supply(address(collateralToken), supplyAmount, address(this), 0);
        emit CollateralSupplied(address(collateralToken), supplyAmount);
    }

    function withdrawCollateral(DataTypesLib.AaveData storage aaveData, uint256 withdrawAmount) external {
        address collateralToken = address(aaveData.collateralToken);
        IPool(aaveData.poolAddressesProvider.getPool()).withdraw(collateralToken, withdrawAmount, address(this));
        emit CollateralWithdrawn(collateralToken, withdrawAmount);
    }

    function mintGHO(DataTypesLib.AaveData storage aaveData, uint256 mintAmount) external {
        IPool(aaveData.poolAddressesProvider.getPool()).borrow(address(aaveData.gho), mintAmount, 2, 0, address(this));
        emit GHOMinted(mintAmount);
    }

    function burnGHO(DataTypesLib.AaveData storage aaveData, uint256 burnAmount) external {
        IPool aavePool = IPool(aaveData.poolAddressesProvider.getPool());
        aaveData.gho.approve(address(aavePool), burnAmount);
        aavePool.repay(address(aaveData.gho), burnAmount, 2, address(this));
        emit GHOBurned(burnAmount);
    }

    function getCurrentFees(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData
    ) external view returns (uint256 fee0, uint256 fee1) {
        (
            uint128 liquidity,
            uint256 feeGrowthInside0Last,
            uint256 feeGrowthInside1Last,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = poolData.pool.positions(getPositionID(poolData));
        (, int24 tick, , , , , ) = poolData.pool.slot0();
        fee0 = _feesEarned(poolData, true, feeGrowthInside0Last, tick, liquidity) + uint256(tokensOwed0);
        fee1 = _feesEarned(poolData, false, feeGrowthInside1Last, tick, liquidity) + uint256(tokensOwed1);
        (fee0, fee1) = _netPerformanceFees(feeData, fee0, fee1);
    }

    function getUserVaults(
        DataTypesLib.UserData storage userData,
        uint256 fromIdx,
        uint256 toIdx
    ) external view returns (DataTypesLib.UserVaultInfo[] memory) {
        if (fromIdx == 0 && toIdx == 0) {
            toIdx = userData.users.length;
        }
        DataTypesLib.UserVaultInfo[] memory usersVaultInfo = new DataTypesLib.UserVaultInfo[](toIdx - fromIdx);
        uint256 count;
        for (uint256 i = fromIdx; i < toIdx; i++) {
            DataTypesLib.UserVault memory userVault = userData.vaults[userData.users[i]];
            usersVaultInfo[count++] = DataTypesLib.UserVaultInfo({user: userData.users[i], token: userVault.token});
        }
        return usersVaultInfo;
    }

    function getPositionID(DataTypesLib.PoolData storage poolData) public view returns (bytes32 positionID) {
        return keccak256(abi.encodePacked(address(this), poolData.lowerTick, poolData.upperTick));
    }

    function getUnderlyingBalance(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        DataTypesLib.AaveData storage aaveData
    ) public view returns (uint256 amountCurrent) {
        (uint160 sqrtRatioX96, int24 tick, , , , , ) = poolData.pool.slot0();
        return _getUnderlyingBalance(poolData, feeData, aaveData, sqrtRatioX96, tick);
    }

    function getUnderlyingBalanceByShare(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        DataTypesLib.AaveData storage aaveData,
        uint256 shares
    ) external view returns (uint256 amount) {
        uint256 _totalSupply = IRangeProtocolVault(address(this)).totalSupply();
        if (_totalSupply != 0) {
            uint256 totalAmount = getUnderlyingBalance(poolData, feeData, aaveData);
            amount = (shares * totalAmount) / _totalSupply;
            amount = _netManagingFees(feeData, amount);
        }
    }

    function _getUnderlyingBalance(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        DataTypesLib.AaveData storage aaveData,
        uint160 sqrtRatioX96,
        int24 tick
    ) internal view returns (uint256 amount) {
        uint256 balanceFromPool = getCurrentBalanceFromPool(poolData, feeData, sqrtRatioX96, tick);
        uint256 token0Balance = poolData.token0.balanceOf(address(this));
        uint256 token1Balance = poolData.token1.balanceOf(address(this));
        if (poolData.isToken0GHO) {
            token0Balance = (token0Balance * 10 ** poolData.decimals1) / 10 ** poolData.decimals0;
        } else {
            token1Balance = (token1Balance * 10 ** poolData.decimals0) / 10 ** poolData.decimals1;
        }

        uint256 balanceFromAave = getCurrentBalanceFromAave(poolData, aaveData);
        return balanceFromPool + token0Balance + token1Balance + balanceFromAave;
    }

    function getCurrentBalanceFromPool(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        uint160 sqrtRatioX96,
        int24 tick
    ) public view returns (uint256 amount) {
        (
            uint128 liquidity,
            uint256 feeGrowthInside0Last,
            uint256 feeGrowthInside1Last,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = poolData.pool.positions(getPositionID(poolData));
        if (liquidity != 0) {
            (uint256 amount0Current, uint256 amount1Current) = LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                poolData.lowerTick.getSqrtRatioAtTick(),
                poolData.upperTick.getSqrtRatioAtTick(),
                liquidity
            );
            uint256 fee0 = _feesEarned(poolData, true, feeGrowthInside0Last, tick, liquidity) + uint256(tokensOwed0);
            uint256 fee1 = _feesEarned(poolData, false, feeGrowthInside1Last, tick, liquidity) + uint256(tokensOwed1);
            (fee0, fee1) = _netPerformanceFees(feeData, fee0, fee1);

            uint8 decimals0 = poolData.decimals0;
            uint8 decimals1 = poolData.decimals1;
            if (poolData.isToken0GHO) {
                amount0Current = (amount0Current * 10 ** decimals1) / 10 ** decimals0;
                fee0 = (fee0 * 10 ** decimals1) / 10 ** decimals0;
            } else {
                amount1Current = (amount1Current * 10 ** decimals0) / 10 ** decimals1;
                fee1 = (fee1 * 10 ** decimals0) / 10 ** decimals1;
            }
            amount = amount0Current + amount1Current + fee0 + fee1;
        }
    }

    function getCurrentBalanceFromAave(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.AaveData storage aaveData
    ) public view returns (uint256 amount) {
        (uint256 totalCollateralBase, uint256 totalDebtBase, , , , ) = IPool(aaveData.poolAddressesProvider.getPool())
            .getUserAccountData(address(this));

        uint256 BASE_CURRENCY_UNIT = IPriceOracleExtended(aaveData.poolAddressesProvider.getPriceOracle())
            .BASE_CURRENCY_UNIT();
        amount = totalCollateralBase - totalDebtBase;
        amount = poolData.isToken0GHO
            ? (amount * 10 ** poolData.decimals1) / BASE_CURRENCY_UNIT
            : (amount * 10 ** poolData.decimals0) / BASE_CURRENCY_UNIT;
    }

    function _beforeTokenTransfer(
        DataTypesLib.UserData storage userData,
        address from,
        address to,
        uint256 amount
    ) external {
        IRangeProtocolVault vault = IRangeProtocolVault(address(this));
        if (from == address(0x0) || to == address(0x0)) return;
        if (!userData.vaults[to].exists) {
            userData.vaults[to].exists = true;
            userData.users.push(to);
        }
        uint256 senderBalance = vault.balanceOf(from);
        uint256 tokenAmount = userData.vaults[from].token -
            (userData.vaults[from].token * (senderBalance - amount)) /
            senderBalance;

        userData.vaults[from].token -= tokenAmount;
        userData.vaults[to].token += tokenAmount;
    }

    function getAavePositionData(
        DataTypesLib.AaveData storage aaveData
    )
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return IPool(aaveData.poolAddressesProvider.getPool()).getUserAccountData(address(this));
    }

    function _validateTicks(int24 _lowerTick, int24 _upperTick, int24 tickSpacing) private pure {
        if (_lowerTick < TickMath.MIN_TICK || _upperTick > TickMath.MAX_TICK) revert VaultErrors.TicksOutOfRange();
        if (_lowerTick >= _upperTick || _lowerTick % tickSpacing != 0 || _upperTick % tickSpacing != 0)
            revert VaultErrors.InvalidTicksSpacing();
    }

    function _withdraw(
        DataTypesLib.PoolData storage poolData,
        uint128 liquidity
    ) internal returns (uint256 burn0, uint256 burn1, uint256 fee0, uint256 fee1) {
        int24 _lowerTick = poolData.lowerTick;
        int24 _upperTick = poolData.upperTick;
        uint256 preBalance0 = poolData.token0.balanceOf(address(this));
        uint256 preBalance1 = poolData.token1.balanceOf(address(this));
        (burn0, burn1) = poolData.pool.burn(_lowerTick, _upperTick, liquidity);
        poolData.pool.collect(address(this), _lowerTick, _upperTick, type(uint128).max, type(uint128).max);
        fee0 = poolData.token0.balanceOf(address(this)) - preBalance0 - burn0;
        fee1 = poolData.token1.balanceOf(address(this)) - preBalance1 - burn1;
    }

    function _feesEarned(
        DataTypesLib.PoolData storage poolData,
        bool isZero,
        uint256 feeGrowthInsideLast,
        int24 tick,
        uint128 liquidity
    ) private view returns (uint256 fee) {
        uint256 feeGrowthOutsideLower;
        uint256 feeGrowthOutsideUpper;
        uint256 feeGrowthGlobal;
        if (isZero) {
            feeGrowthGlobal = poolData.pool.feeGrowthGlobal0X128();
            (, , feeGrowthOutsideLower, , , , , ) = poolData.pool.ticks(poolData.lowerTick);
            (, , feeGrowthOutsideUpper, , , , , ) = poolData.pool.ticks(poolData.upperTick);
        } else {
            feeGrowthGlobal = poolData.pool.feeGrowthGlobal1X128();
            (, , , feeGrowthOutsideLower, , , , ) = poolData.pool.ticks(poolData.lowerTick);
            (, , , feeGrowthOutsideUpper, , , , ) = poolData.pool.ticks(poolData.upperTick);
        }

        unchecked {
            uint256 feeGrowthBelow;
            if (tick >= poolData.lowerTick) {
                feeGrowthBelow = feeGrowthOutsideLower;
            } else {
                feeGrowthBelow = feeGrowthGlobal - feeGrowthOutsideLower;
            }

            uint256 feeGrowthAbove;
            if (tick < poolData.upperTick) {
                feeGrowthAbove = feeGrowthOutsideUpper;
            } else {
                feeGrowthAbove = feeGrowthGlobal - feeGrowthOutsideUpper;
            }
            uint256 feeGrowthInside = feeGrowthGlobal - feeGrowthBelow - feeGrowthAbove;

            fee = FullMath.mulDiv(
                liquidity,
                feeGrowthInside - feeGrowthInsideLast,
                0x100000000000000000000000000000000
            );
        }
    }

    function _applyManagingFee(DataTypesLib.FeeData storage feeData, uint256 amount) private {
        feeData.managerBalanceToken += (amount * feeData.managingFee) / 10_000;
    }

    function _applyPerformanceFee(
        DataTypesLib.PoolData storage poolData,
        DataTypesLib.FeeData storage feeData,
        DataTypesLib.AaveData storage aaveData,
        uint256 fee0,
        uint256 fee1
    ) private {
        uint256 _performanceFee = feeData.performanceFee;
        if (poolData.token0 == aaveData.gho) {
            feeData.managerBalanceGHO += (fee0 * _performanceFee) / 10_000;
            feeData.managerBalanceToken += (fee1 * _performanceFee) / 10_000;
        } else {
            feeData.managerBalanceToken += (fee0 * _performanceFee) / 10_000;
            feeData.managerBalanceGHO += (fee1 * _performanceFee) / 10_000;
        }
    }

    function _netManagingFees(
        DataTypesLib.FeeData storage feeData,
        uint256 amount
    ) private view returns (uint256 amountAfterFee) {
        uint256 deduct = (amount * feeData.managingFee) / 10_000;
        amountAfterFee = amount - deduct;
    }

    function _netPerformanceFees(
        DataTypesLib.FeeData storage feeData,
        uint256 rawFee0,
        uint256 rawFee1
    ) private view returns (uint256 fee0AfterDeduction, uint256 fee1AfterDeduction) {
        uint256 _performanceFee = feeData.performanceFee;
        uint256 deduct0 = (rawFee0 * _performanceFee) / 10_000;
        uint256 deduct1 = (rawFee1 * _performanceFee) / 10_000;
        fee0AfterDeduction = rawFee0 - deduct0;
        fee1AfterDeduction = rawFee1 - deduct1;
    }
}
