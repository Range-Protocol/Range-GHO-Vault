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

/**
 * @notice RangeProtocolVault is vault for AMM pools where a collateral token is paired with Aave's GHO token.
 * It has mint and burn functions for the users to provide liquidity in collateral token to the vault and has
 * functions removeLiquidity, addLiquidity and swap for the manager to manage liquidity. Upon vault deployment, the
 * manager calls updateTicks function to start the minting process by users at a specified tick range. Once the mint
 * has started, the liquidity provided by users directly go to the AMM pool. The manager can remove liquidity from
 * the AMM pool and for providing liquidity into a newer tick range, manager will perform swap to have tokens in ratio
 * accordingly to the newer tick range and call addLiquidity function to add to a newer tick range.
 */
contract RangeProtocolVault is
    Initializable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    OwnableUpgradeable,
    ERC20Upgradeable,
    PausableUpgradeable,
    RangeProtocolVaultStorage
{
    // @notice restricts the call by self. It used to restrict the allowed calls only from the LogicLib.
    modifier onlyVault() {
        if (msg.sender != address(this)) revert VaultErrors.OnlyVaultAllowed();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    // @notice initialised the vault's initial sate.
    // @param _pool address of pool with which the vault interacts.
    // @param _tickSpacing tick spacing of the pool.
    // @param data additional data of the vault.
    function initialize(address _pool, int24 _tickSpacing, bytes memory data) external override initializer {
        (
            address manager,
            string memory _name,
            string memory _symbol,
            address _gho,
            address _poolAddressesProvider,
            address _collateralPriceOracleAddress,
            uint256 _collateralPriceOracleHeartbeat,
            address _ghoPriceOracleAddress,
            uint256 _ghoPriceOracleHeartbeat
        ) = abi.decode(data, (address, string, string, address, address, address, uint256, address, uint256));
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Ownable_init();
        __ERC20_init(_name, _symbol);
        __Pausable_init();
        _transferOwnership(manager);

        if (manager == address(0x0)) revert VaultErrors.ZeroManagerAddress();
        if (address(IUniswapV3Pool(_pool).token0()) != _gho) revert VaultErrors.TokenZeroIsNotGHO();

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
        state.collateralPriceOracle = DataTypesLib.PriceOracle(
            AggregatorV3Interface(_collateralPriceOracleAddress),
            _collateralPriceOracleHeartbeat
        );
        state.ghoPriceOracle = DataTypesLib.PriceOracle(
            AggregatorV3Interface(_ghoPriceOracleAddress),
            _ghoPriceOracleHeartbeat
        );

        state.vaultDecimals = address(token0) == _gho
            ? state.vaultDecimals = decimals1
            : state.vaultDecimals = decimals0;

        // Managing fee is 0.1% and performance fee is 10% at the time vault initialization.
        LogicLib.updateFees(state, 10, 1000);
    }

    // @notice pauses the mint and burn functions. It can only be called by the vault manager.
    function pause() external onlyManager {
        _pause();
    }

    // @notice unpauses the mint and burn functions. It can only be called by the vault manager.
    function unpause() external onlyManager {
        _unpause();
    }

    // @notice mints shares to the provided address. Only the vault itself is allowed to call this function. The LogicLib
    // used by the vault calls to mint shares to an address.
    // @param to the address to mint shares to.
    // @param shares the amount of shares to mint.
    function mintShares(address to, uint256 shares) external override onlyVault {
        _mint(to, shares);
    }

    // @notice burns shares from the provided address. Only the vault itself is allowed to call this function. The LogicLib
    // used by the vault calls to burn shares from an address.
    // @notice from the address to burn shares from.
    // @notice shares the amount of shares to burn.
    function burnShares(address from, uint256 shares) external override onlyVault {
        _burn(from, shares);
    }

    // @notice uniswapV3 mint callback implementation. Calls uniswapV3MintCallback on the LogicLib to execute logic.
    // @param amount0Owed amount in token0 to transfer.
    // @param amount1Owed amount in token1 to transfer.
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external override {
        LogicLib.uniswapV3MintCallback(state, amount0Owed, amount1Owed);
    }

    // @notice uniswapV3 swap callback implementation. Calls uniswapV3SwapCallback on the LogicLib to execute logic.
    // @param amount0Delta amount0 added (+) or to be taken (-) from the vault.
    // @param amount1Delta amount1 added (+) or to be taken (-) from the vault.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external override {
        LogicLib.uniswapV3SwapCallback(state, amount0Delta, amount1Delta);
    }

    // @notice called by the user with collateral amount to provide liquidity in collateral amount. Calls mint function
    // on the LogicLib to execute logic.
    // @param amount the amount of collateral to provide.
    // @param minShares the minimum shares to mint.
    // @return shares the amount of shares minted.
    function mint(
        uint256 amount,
        uint256 minShares
    ) external override nonReentrant whenNotPaused returns (uint256 shares) {
        return LogicLib.mint(state, amount, minShares);
    }

    // @notice called by the user with share amount to burn their vault shares redeem their share of the asset. Calls
    // burn function on the LogicLib to execute logic.
    // @param burnAmount the amount of vault shares to burn.
    // @return amount the amount of assets in collateral token received by the user.
    function burn(
        uint256 burnAmount,
        uint256 minAmount
    ) external override nonReentrant whenNotPaused returns (uint256 amount) {
        return LogicLib.burn(state, burnAmount, minAmount);
    }

    // @notice called by manager to remove liquidity from the pool. Calls removeLiquidity function on the LogcLib.
    function removeLiquidity(uint256[2] calldata minAmounts) external override onlyManager {
        LogicLib.removeLiquidity(state, minAmounts);
    }

    // @notice called by manager to perform swap from token0 to token1 and vice-versa. Calls swap function on the LogicLib.
    // @param zeroForOne swap direction (true -> x to y) or (false -> y to x)
    // @param swapAmount amount to swap (+ve -> exact in, -ve exact out)
    // @param sqrtPriceLimitX96 the limit pool price can move when filling the order.
    // @param amount0 amount0 added (+) or to be taken (-) from the vault.
    // @param amount1 amount1 added (+) or to be taken (-) from the vault.
    function swap(
        bool zeroForOne,
        int256 swapAmount,
        uint160 sqrtPriceLimitX96,
        uint256 minAmountIn
    ) external override onlyManager returns (int256 amount0, int256 amount1) {
        return LogicLib.swap(state, zeroForOne, swapAmount, sqrtPriceLimitX96, minAmountIn);
    }

    // @notice called by manager to provide liquidity to pool into a newer tick range. Calls addLiquidity function on
    // the LogicLib.
    // @param newLowerTick lower tick of the position.
    // @param newUpperTick upper tick of the position.
    // @param amount0 amount in token0 to add.
    // @param amount1 amount in token1 to add.
    // @return remainingAmount0 amount in token0 left passive in the vault.
    // @return remainingAmount1 amount in token1 left passive in the vault.
    function addLiquidity(
        int24 newLowerTick,
        int24 newUpperTick,
        uint256 amount0,
        uint256 amount1,
        uint256[2] calldata maxAmounts
    ) external override onlyManager returns (uint256 remainingAmount0, uint256 remainingAmount1) {
        return LogicLib.addLiquidity(state, newLowerTick, newUpperTick, amount0, amount1, maxAmounts);
    }

    // @notice called by manager to transfer the unclaimed fee from pool to the vault. Calls pullFeeFromPool function on
    // the LogicLib.
    function pullFeeFromPool() external onlyManager {
        LogicLib.pullFeeFromPool(state);
    }

    // @notice called by manager to collect fee from the vault. Calls collectManager function on the LogicLib.
    function collectManager() external override onlyManager {
        LogicLib.collectManager(state, manager());
    }

    // @notice called by the manager to update the fees. Calls updateFees function on the LogicLib.
    // @param newManagingFee new managing fee percentage out of 10_000.
    // @param newPerformanceFee new performance fee percentage out of 10_000.
    function updateFees(uint16 newManagingFee, uint16 newPerformanceFee) external override onlyManager {
        LogicLib.updateFees(state, newManagingFee, newPerformanceFee);
    }

    /**
     * @notice returns current unclaimed fees from the pool. Calls getCurrentFees on the LogicLib.
     * @return fee0 fee in token0
     * @return fee1 fee in token1
     */
    function getCurrentFees() external view override returns (uint256 fee0, uint256 fee1) {
        return LogicLib.getCurrentFees(state);
    }

    /**
     * @notice returns user vaults based on the provided index. Calls getUserVaults on LogicLib.
     * @param fromIdx the starting index to fetch users.
     * @param toIdx the ending index to fetch users.
     * @return UserVaultInfo
     */
    function getUserVaults(
        uint256 fromIdx,
        uint256 toIdx
    ) external view override returns (DataTypesLib.UserVaultInfo[] memory) {
        return LogicLib.getUserVaults(state, fromIdx, toIdx);
    }

    // @notice supplied collateral to Aave. Called by manager only.
    // @param supplyAmount amount of collateral to supply.
    function supplyCollateral(uint256 supplyAmount) external override onlyManager {
        LogicLib.supplyCollateral(state, supplyAmount);
    }

    // @notice withdraws collateral from Aave. Called by manager only.
    // @param withdrawAmount amount of collateral to withdraw.
    function withdrawCollateral(uint256 withdrawAmount) external override onlyManager {
        LogicLib.withdrawCollateral(state, withdrawAmount);
    }

    // @notice borrows GHO token from Aave. Called by manager only.
    // @param mint amount of GHO to mint.
    function mintGHO(uint256 mintAmount) external override onlyManager {
        LogicLib.mintGHO(state, mintAmount);
    }

    // @notice payback GHO debt to Aave. Called by manager only.
    // @param burnAmount amount of GHO debt to payback.
    function burnGHO(uint256 burnAmount) external override onlyManager {
        LogicLib.burnGHO(state, burnAmount);
    }

    // @notice a multicall function to repeg the pool through the number of actions supplying/withdrawing collateral,
    // minting/burning of gho and performing swap on the uni pool.
    function repegPool(bytes[] memory calldatas) external override onlyManager returns (bytes[] memory returndatas) {
        returndatas = new bytes[](calldatas.length);
        for (uint256 i = 0; i < calldatas.length; i++) {
            (bool success, bytes memory returndata) = address(this).delegatecall(calldatas[i]);
            if (!success) {
                if (returndata.length > 0) {
                    assembly {
                        revert(add(32, returndata), mload(returndata))
                    }
                }
                revert VaultErrors.PoolRepegFailed();
            }
            returndatas[i] = returndata;
        }

        emit PoolRepegged();
    }

    // @notice updates the hearbeat duration of collateral and gho price oracles.
    // @param collateralOracleHBDuration heartbeat duration for collateral price oracle.
    // @param ghoOracleHBDuration heartbeat duration for gho price oracle.
    function updatePriceOracleHeartbeatsDuration(
        uint256 collateralOracleHBDuration,
        uint256 ghoOracleHBDuration
    ) external override onlyManager {
        LogicLib.updatePriceOracleHeartbeatsDuration(state, collateralOracleHBDuration, ghoOracleHBDuration);
    }

    /**
     * @notice returns Aave position data.
     * @return totalCollateralBase total collateral supplied.
     * @return totalDebtBase total debt borrowed.
     * @return availableBorrowsBase available amount to borrow.
     * @return currentLiquidationThreshold current threshold for liquidation to trigger.
     * @return ltv Loan-to-value ratio of the position.
     * @return healthFactor current health factor of the position.
     */
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

    // @notice returns decimals of the vault token.
    // @return decimals of vault shares.
    function decimals() public view override returns (uint8) {
        return state.vaultDecimals;
    }

    // @notice returns position id of the vault in pool.
    // @return positionId the id of the position in pool.
    function getPositionID() public view override returns (bytes32 positionID) {
        return LogicLib.getPositionID(state);
    }

    // @notice returns underlying balance in collateral token based on the shares amount passed.
    // @param shares amount of vault to calculate the redeemable amount against.
    // @return amount the amount of asset in collateral token redeemable against the provided amount of collateral.
    function getUnderlyingBalanceByShare(uint256 shares) external view override returns (uint256 amount) {
        return LogicLib.getUnderlyingBalanceByShare(state, shares);
    }

    // @notice returns vault asset's balance in collateral token.
    // @return amount the amount of vault holding converted to collateral token.
    function getBalanceInCollateralToken() public view override returns (uint256 amount) {
        return LogicLib.getBalanceInCollateralToken(state);
    }

    function getUnderlyingBalancesFromPool() external view override returns (uint256, uint256) {
        (uint160 sqrtRatioX96, int24 tick, , , , , ) = state.pool.slot0();
        return LogicLib.getUnderlyingBalancesFromPool(state, sqrtRatioX96, tick);
    }

    function getUnderlyingBalancesFromAave() external view override returns (uint256, uint256) {
        return LogicLib.getUnderlyingBalancesFromAave(state);
    }

    // @notice restricts upgrading of vault to factory only.
    function _authorizeUpgrade(address) internal override {
        if (msg.sender != state.factory) revert VaultErrors.OnlyFactoryAllowed();
    }

    // @notice transfer hook to transfer the exposure from sender to recipient. Calls _beforeTokenTransfer on the LogicLib.
    // @param from the sender of vault shares.
    // @param to recipient of vault shares.
    // @param amount amount of vault shares to transfer.
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        LogicLib._beforeTokenTransfer(state, from, to, amount);
    }
}
