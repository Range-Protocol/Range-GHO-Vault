//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {RangeProtocolVaultStorage} from "./RangeProtocolVaultStorage.sol";
import {IRangeProtocolVault} from "./interfaces/IRangeProtocolVault.sol";
import {OwnableUpgradeable} from "./access/OwnableUpgradeable.sol";
import {DataTypesLib} from "./libraries/DataTypesLib.sol";
import {LogicLib} from "./libraries/LogicLib.sol";
import {VaultErrors} from "./errors/VaultErrors.sol";

contract RangeProtocolVault is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    ERC20Upgradeable,
    PausableUpgradeable,
    RangeProtocolVaultStorage
{
    modifier onlyVault() {
        if (msg.sender != address(this)) revert VaultErrors.OnlyVaultAllowed();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address _pool, int24 _tickSpacing, bytes memory data) external override initializer {
        (
            address manager,
            string memory _name,
            string memory _symbol,
            address _gho,
            address _poolAddressesProvider,
            address _collateralTokenPriceFeed,
            address _ghoPriceFeed
        ) = abi.decode(data, (address, string, string, address, address, address, address));
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Ownable_init();
        __ERC20_init(_name, _symbol);
        __Pausable_init();
        _transferOwnership(manager);

        state.pool = IUniswapV3Pool(_pool);
        IERC20Upgradeable token0 = IERC20Upgradeable(state.pool.token0());
        IERC20Upgradeable token1 = IERC20Upgradeable(state.pool.token1());
        state.token0 = token0;
        state.token1 = token1;
        state.tickSpacing = _tickSpacing;
        state.factory = msg.sender;
        uint8 decimals0 = IERC20MetadataUpgradeable(address(token0)).decimals();
        uint8 decimals1 = IERC20MetadataUpgradeable(address(token1)).decimals();
        state.decimals0 = decimals0;
        state.decimals1 = decimals1;
        state.poolAddressesProvider = IPoolAddressesProvider(_poolAddressesProvider);
        state.collateralTokenPriceFeed = AggregatorV3Interface(_collateralTokenPriceFeed);
        state.ghoPriceFeed = AggregatorV3Interface(_ghoPriceFeed);

        if (address(token0) == _gho) {
            state.isToken0GHO = true;
            state.vaultDecimals = decimals1;
        } else {
            state.vaultDecimals = decimals0;
        }
        // Managing fee is 0% at the time vault initialization.
        LogicLib.updateFees(state, 10, 250);
    }

    function updateTicks(int24 _lowerTick, int24 _upperTick) external override onlyManager {
        LogicLib.updateTicks(state, _lowerTick, _upperTick);
    }

    function pause() external onlyManager {
        _pause();
    }

    function unpause() external onlyManager {
        _unpause();
    }

    function mintShares(address to, uint256 shares) external override onlyVault {
        _mint(to, shares);
    }

    function burnShares(address from, uint256 shares) external override onlyVault {
        _burn(from, shares);
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external override {
        LogicLib.uniswapV3MintCallback(state, amount0Owed, amount1Owed);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        LogicLib.uniswapV3SwapCallback(state, amount0Delta, amount1Delta);
    }

    function mint(uint256 amount) external override nonReentrant whenNotPaused returns (uint256 shares) {
        return LogicLib.mint(state, amount);
    }

    function burn(uint256 burnAmount) external override nonReentrant whenNotPaused returns (uint256 amount) {
        return LogicLib.burn(state, burnAmount);
    }

    function removeLiquidity() external override onlyManager {
        LogicLib.removeLiquidity(state);
    }

    function swap(
        bool zeroForOne,
        int256 swapAmount,
        uint160 sqrtPriceLimitX96
    ) external override onlyManager returns (int256 amount0, int256 amount1) {
        return LogicLib.swap(state, zeroForOne, swapAmount, sqrtPriceLimitX96);
    }

    function addLiquidity(
        int24 newLowerTick,
        int24 newUpperTick,
        uint256 amount0,
        uint256 amount1
    ) external override onlyManager returns (uint256 remainingAmount0, uint256 remainingAmount1) {
        return LogicLib.addLiquidity(state, newLowerTick, newUpperTick, amount0, amount1);
    }

    function pullFeeFromPool() external onlyManager {
        LogicLib.pullFeeFromPool(state);
    }

    function collectManager() external override onlyManager {
        LogicLib.collectManager(state, manager());
    }

    function updateFees(uint16 newManagingFee, uint16 newPerformanceFee) external override onlyManager {
        LogicLib.updateFees(state, newManagingFee, newPerformanceFee);
    }

    function getCurrentFees() external view override returns (uint256 fee0, uint256 fee1) {
        return LogicLib.getCurrentFees(state);
    }

    function getUserVaults(
        uint256 fromIdx,
        uint256 toIdx
    ) external view override returns (DataTypesLib.UserVaultInfo[] memory) {
        return LogicLib.getUserVaults(state, fromIdx, toIdx);
    }

    function supplyCollateral(uint256 supplyAmount) external override onlyManager {
        LogicLib.supplyCollateral(state, supplyAmount);
    }

    function withdrawCollateral(uint256 withdrawAmount) external override onlyManager {
        LogicLib.withdrawCollateral(state, withdrawAmount);
    }

    function mintGHO(uint256 mintAmount) external override onlyManager {
        LogicLib.mintGHO(state, mintAmount);
    }

    function burnGHO(uint256 burnAmount) external override onlyManager {
        LogicLib.burnGHO(state, burnAmount);
    }

    function getAavePositionData()
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
        return LogicLib.getAavePositionData(state);
    }

    function decimals() public view override returns (uint8) {
        return state.vaultDecimals;
    }

    function getPositionID() public view override returns (bytes32 positionID) {
        return LogicLib.getPositionID(state);
    }

    function getUnderlyingBalancesByShare(uint256 shares) external view override returns (uint256 amount) {
        return LogicLib.getUnderlyingBalancesByShare(state, shares);
    }

    function getBalanceInCollateralToken() public view override returns (uint256 amount) {
        return LogicLib.getBalanceInCollateralToken(state);
    }

    function _authorizeUpgrade(address) internal override {
        if (msg.sender != state.factory) revert VaultErrors.OnlyFactoryAllowed();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        LogicLib._beforeTokenTransfer(state, from, to, amount);
    }
}
