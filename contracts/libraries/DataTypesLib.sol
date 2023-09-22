//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";

library DataTypesLib {
    struct UserVault {
        bool exists;
        uint256 token;
    }

    struct UserVaultInfo {
        address user;
        uint256 token;
    }

    struct PriceOracle {
        AggregatorV3Interface priceFeed;
        uint256 heartbeatDuration;
    }

    struct State {
        address factory;
        IUniswapV3Pool pool;
        IERC20Upgradeable token0;
        IERC20Upgradeable token1;
        int24 lowerTick;
        int24 upperTick;
        int24 tickSpacing;
        bool inThePosition;
        uint8 decimals0;
        uint8 decimals1;
        uint8 vaultDecimals;
        uint16 managingFee;
        uint16 performanceFee;
        uint256 managerBalance;
        IPoolAddressesProvider poolAddressesProvider;
        PriceOracle collateralPriceOracle;
        PriceOracle ghoPriceOracle;
        mapping(address => UserVault) vaults;
        address[] users;
    }
}
