//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {DataTypesLib} from "./libraries/DataTypesLib.sol";
import {IRangeProtocolVault} from "./interfaces/IRangeProtocolVault.sol";

abstract contract RangeProtocolVaultStorage is IRangeProtocolVault {
    DataTypesLib.State internal state;

    function factory() external view override returns (address) {
        return state.poolData.factory;
    }

    function pool() external view override returns (IUniswapV3Pool) {
        return state.poolData.pool;
    }

    function token0() external view override returns (IERC20Upgradeable) {
        return state.poolData.token0;
    }

    function token1() external view override returns (IERC20Upgradeable) {
        return state.poolData.token1;
    }

    function lowerTick() external view override returns (int24) {
        return state.poolData.lowerTick;
    }

    function upperTick() external view override returns (int24) {
        return state.poolData.upperTick;
    }

    function tickSpacing() external view override returns (int24) {
        return state.poolData.tickSpacing;
    }

    function inThePosition() external view override returns (bool) {
        return state.poolData.inThePosition;
    }

    function isToken0GHO() external view override returns (bool) {
        return state.poolData.isToken0GHO;
    }

    function managingFee() external view override returns (uint16) {
        return state.feeData.managingFee;
    }

    function performanceFee() external view override returns (uint16) {
        return state.feeData.performanceFee;
    }

    function managerBalanceGHO() external view override returns (uint256) {
        return state.feeData.managerBalanceGHO;
    }

    function managerBalanceToken() external view override returns (uint256) {
        return state.feeData.managerBalanceToken;
    }

    function userVaults(
        address user
    ) external view override returns (DataTypesLib.UserVault memory) {
        return state.userData.vaults[user];
    }

    function userCount() external view override returns (uint256) {
        return state.userData.users.length;
    }

    function users(uint256 index) external view override returns (address) {
        return state.userData.users[index];
    }

    function poolAddressesProvider() external view override returns (address) {
        return address(state.aaveData.poolAddressesProvider);
    }

    function gho() external view override returns (address) {
        return address(state.aaveData.gho);
    }

    function collateralToken() external view override returns (address) {
        return address(state.aaveData.collateralToken);
    }
}
