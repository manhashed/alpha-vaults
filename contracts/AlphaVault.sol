// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IVaultAdapter} from "./interfaces/IVaultAdapter.sol";
import {ICoreDepositor} from "./interfaces/ICoreDepositor.sol";
import {IAlphaVault} from "./interfaces/IAlphaVault.sol";
import {HyperCoreReadPrecompile} from "./libraries/HyperCoreReadPrecompile.sol";
import {HyperCoreWritePrecompile} from "./libraries/HyperCoreWritePrecompile.sol";
import {StrategyLib} from "./libraries/StrategyLib.sol";
import {
    StrategyType,
    StrategyInput,
    Strategy,
    WithdrawalRequest,
    BPS_DENOMINATOR,
    DEFAULT_EPOCH_LENGTH,
    DEFAULT_DEPLOYMENT_INTERVAL,
    DEFAULT_DEPOSIT_FEE_BPS,
    DEFAULT_WITHDRAW_FEE_BPS,
    MAX_FEE_BPS,
    DEFAULT_RESERVE_FLOOR_BPS,
    DEFAULT_RESERVE_TARGET_BPS,
    DEFAULT_RESERVE_CEIL_BPS,
    DEFAULT_PERP_DEX_INDEX,
    USDC_DECIMALS
} from "./types/VaultTypes.sol";

/**
 * @title AlphaVault
 * @notice ERC-4626 index vault with epoch-based settlement and fixed strategy composition.
 */
contract AlphaVault is
    Initializable,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IAlphaVault
{
    using SafeERC20 for IERC20;

    // ═══════════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════════

    struct DepositEntry {
        address depositor;
        address receiver;
        uint256 assets;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════════

    Strategy[] private _strategies;

    address public treasury;
    address public coreDepositor;
    address public perpsSubAccount;

    uint32 public perpDexIndex;
    uint64 public perpsUsdcTokenId;
    uint64 public perpsUsdcScale;

    uint16 public depositFeeBps;
    uint16 public withdrawFeeBps;

    uint16 public reserveFloorBps;
    uint16 public reserveTargetBps;
    uint16 public reserveCeilBps;

    uint256 public epochLength;
    bool public deploymentPaused;

    mapping(uint256 => bool) public epochSettled;
    mapping(uint256 => uint256) public epochPendingDeposits;
    mapping(uint256 => uint256) public epochWithdrawalCounts;
    uint256 public totalPendingDeposits;

    mapping(uint256 => DepositEntry[]) private _epochDeposits;

    WithdrawalRequest[] private _withdrawalQueue;
    uint256 public withdrawalQueueHead;
    uint256 public deploymentInterval;
    uint256 public maxDeploymentAmount;
    uint256 public lastDeploymentAt;
    uint256 public pendingWithdrawalAssets;
    address public deploymentOperator;

    uint256[45] private __gap;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVENTS (extra)
    // ═══════════════════════════════════════════════════════════════════════════

    event FeesCollected(address indexed treasury, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════════
    // ERRORS
    // ═══════════════════════════════════════════════════════════════════════════

    error AdapterOperationFailed(address adapter);

    modifier onlyDeploymentOperator() {
        if (msg.sender != owner() && msg.sender != deploymentOperator) revert DeploymentUnauthorized();
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INITIALIZER
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address asset_,
        string memory name_,
        string memory symbol_,
        address treasury_,
        address coreDepositor_,
        address owner_
    ) external initializer {
        if (asset_ == address(0)) revert ZeroAddress();
        if (treasury_ == address(0)) revert ZeroAddress();
        if (coreDepositor_ == address(0)) revert ZeroAddress();
        if (owner_ == address(0)) revert ZeroAddress();

        __ERC20_init(name_, symbol_);
        __ERC4626_init(IERC20(asset_));
        __Ownable_init(owner_);
        __Pausable_init();
        __ReentrancyGuard_init();

        treasury = treasury_;
        coreDepositor = coreDepositor_;
        perpsSubAccount = address(0);

        perpDexIndex = DEFAULT_PERP_DEX_INDEX;
        perpsUsdcTokenId = 0;
        perpsUsdcScale = uint64(USDC_DECIMALS);

        epochLength = DEFAULT_EPOCH_LENGTH;
        depositFeeBps = DEFAULT_DEPOSIT_FEE_BPS;
        withdrawFeeBps = DEFAULT_WITHDRAW_FEE_BPS;

        reserveFloorBps = DEFAULT_RESERVE_FLOOR_BPS;
        reserveTargetBps = DEFAULT_RESERVE_TARGET_BPS;
        reserveCeilBps = DEFAULT_RESERVE_CEIL_BPS;

        deploymentInterval = DEFAULT_DEPLOYMENT_INTERVAL;
        maxDeploymentAmount = 0;
        lastDeploymentAt = 0;
        pendingWithdrawalAssets = 0;
        deploymentOperator = owner_;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EPOCH FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getCurrentEpoch() public view returns (uint256) {
        return block.timestamp / epochLength;
    }

    function getTimeUntilNextEpoch() external view returns (uint256) {
        return (getCurrentEpoch() + 1) * epochLength - block.timestamp;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ERC-4626 OVERRIDES - Queued
    // ═══════════════════════════════════════════════════════════════════════════

    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 total = _availableL1();
        total += _erc4626TVL();
        total = _applySignedBalance(total, _perpsBalance());
        total += _vaultTVL();
        return _applyPendingWithdrawals(total);
    }

    function previewDeposit(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 netAssets = _applyFee(assets, depositFeeBps);
        return super.previewDeposit(netAssets);
    }

    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 netAssets = super.previewMint(shares);
        if (depositFeeBps == 0) return netAssets;
        return Math.mulDiv(netAssets, BPS_DENOMINATOR, BPS_DENOMINATOR - depositFeeBps);
    }

    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return super.previewWithdraw(assets);
    }

    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return super.previewRedeem(shares);
    }

    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (_strategies.length == 0) revert StrategyRegistryEmpty();

        uint256 fee = _calculateFee(assets, depositFeeBps);
        uint256 netAssets = assets - fee;
        shares = previewDeposit(assets);
        if (shares == 0) revert InvalidAmount();

        uint256 epoch = getCurrentEpoch();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _collectFee(fee);

        _epochDeposits[epoch].push(DepositEntry({depositor: msg.sender, receiver: receiver, assets: netAssets}));
        epochPendingDeposits[epoch] += netAssets;
        totalPendingDeposits += netAssets;

        emit DepositQueued(msg.sender, receiver, netAssets, fee, epoch);
        emit Deposit(msg.sender, receiver, netAssets, shares);
    }

    function mint(uint256 shares, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (_strategies.length == 0) revert StrategyRegistryEmpty();

        uint256 netAssets = super.previewMint(shares);
        if (netAssets == 0) revert InvalidAmount();

        assets = previewMint(shares);
        uint256 fee = assets - netAssets;

        uint256 epoch = getCurrentEpoch();

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _collectFee(fee);

        _epochDeposits[epoch].push(DepositEntry({depositor: msg.sender, receiver: receiver, assets: netAssets}));
        epochPendingDeposits[epoch] += netAssets;
        totalPendingDeposits += netAssets;

        emit DepositQueued(msg.sender, receiver, netAssets, fee, epoch);
        emit Deposit(msg.sender, receiver, netAssets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();

        shares = previewWithdraw(assets);
        if (shares == 0 || shares > balanceOf(owner)) revert InvalidAmount();

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        uint256 epoch = getCurrentEpoch();
        uint256 fee = _calculateFee(assets, withdrawFeeBps);
        pendingWithdrawalAssets += assets;

        _withdrawalQueue.push(WithdrawalRequest({
            owner: owner,
            receiver: receiver,
            assets: assets,
            shares: shares,
            epoch: epoch
        }));
        epochWithdrawalCounts[epoch] += 1;

        emit WithdrawalQueued(owner, receiver, assets, fee, shares, epoch);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        whenNotPaused
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0 || shares > balanceOf(owner)) revert InvalidAmount();
        if (receiver == address(0)) revert ZeroAddress();

        assets = previewRedeem(shares);
        if (assets == 0) revert InvalidAmount();

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }
        _burn(owner, shares);
        uint256 epoch = getCurrentEpoch();
        uint256 fee = _calculateFee(assets, withdrawFeeBps);
        pendingWithdrawalAssets += assets;

        _withdrawalQueue.push(WithdrawalRequest({
            owner: owner,
            receiver: receiver,
            assets: assets,
            shares: shares,
            epoch: epoch
        }));
        epochWithdrawalCounts[epoch] += 1;

        emit WithdrawalQueued(owner, receiver, assets, fee, shares, epoch);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EPOCH SETTLEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function settleEpoch(uint256 epochId) external nonReentrant whenNotPaused {
        if (epochSettled[epochId]) revert InvalidAmount();
        if (epochId >= getCurrentEpoch()) revert InvalidAmount();

        uint256 depositAssets = epochPendingDeposits[epochId];
        uint256 supplyBefore = totalSupply();
        uint256 assetsBefore = totalAssets();
        uint256 virtualShares = 10 ** uint256(_decimalsOffset());
        uint256 sharesDenom = supplyBefore + virtualShares;
        uint256 assetsNum = assetsBefore + 1;

        uint256 sharesMinted;
        if (depositAssets > 0) {
            DepositEntry[] storage entries = _epochDeposits[epochId];
            for (uint256 i = 0; i < entries.length; i++) {
                uint256 entryAssets = entries[i].assets;
                if (entryAssets == 0) continue;

                uint256 userShares = Math.mulDiv(entryAssets, sharesDenom, assetsNum);

                if (userShares > 0) {
                    _mint(entries[i].receiver, userShares);
                    sharesMinted += userShares;
                    emit DepositSettled(entries[i].receiver, entryAssets, userShares, epochId);
                }
            }

            epochPendingDeposits[epochId] = 0;
            totalPendingDeposits = totalPendingDeposits > depositAssets ? totalPendingDeposits - depositAssets : 0;
            delete _epochDeposits[epochId];
        }

        uint256 withdrawAssetsPaid = _processWithdrawals(epochId);

        epochSettled[epochId] = true;
        emit EpochSettled(epochId, depositAssets, withdrawAssetsPaid, sharesMinted);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // STRATEGY REGISTRY
    // ═══════════════════════════════════════════════════════════════════════════

    function setStrategies(StrategyInput[] calldata inputs) external onlyOwner {
        StrategyLib.validateStrategyInputs(inputs);

        // Ensure removed strategies have zero TVL
        for (uint256 i = 0; i < _strategies.length; i++) {
            Strategy memory existing = _strategies[i];
            if (existing.adapter == address(0)) continue;

            bool found;
            for (uint256 j = 0; j < inputs.length; j++) {
                if (inputs[j].adapter == existing.adapter) {
                    found = true;
                    break;
                }
            }

            if (!found) {
                uint256 tvl = IVaultAdapter(existing.adapter).getTVL();
                if (tvl > 0) revert StrategyNotFound();
            }
        }

        delete _strategies;
        for (uint256 i = 0; i < inputs.length; i++) {
            _strategies.push(Strategy({
                adapter: inputs[i].adapter,
                targetBps: inputs[i].targetBps,
                strategyType: inputs[i].strategyType,
                active: inputs[i].active
            }));
        }

        emit StrategyRegistryUpdated(inputs);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function getStrategies() external view returns (Strategy[] memory strategies) {
        strategies = _strategies;
    }

    function getEpochSummary(uint256 epochId) external view returns (uint256, uint256, bool) {
        return (epochPendingDeposits[epochId], epochWithdrawalCounts[epochId], epochSettled[epochId]);
    }

    function getEpochDepositCount(uint256 epochId) external view returns (uint256) {
        return _epochDeposits[epochId].length;
    }

    function getEpochWithdrawalCount(uint256 epochId) external view returns (uint256) {
        return epochWithdrawalCounts[epochId];
    }

    function getFees() external view returns (uint16 depositFee, uint16 withdrawFee) {
        return (depositFeeBps, withdrawFeeBps);
    }

    function getWithdrawableLiquidity() external view returns (uint256 assets) {
        return _getWithdrawableLiquidity();
    }

    function getReserveConfig() external view returns (uint16 floorBps, uint16 targetBps, uint16 ceilBps) {
        return (reserveFloorBps, reserveTargetBps, reserveCeilBps);
    }

    function getWithdrawalQueueLength() external view returns (uint256) {
        return _withdrawalQueue.length - withdrawalQueueHead;
    }

    function getWithdrawalRequest(uint256 index) external view returns (WithdrawalRequest memory) {
        return _withdrawalQueue[index];
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DEPLOYMENT FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function deployBatch()
        external
        whenNotPaused
        nonReentrant
        onlyDeploymentOperator
        returns (uint256 deployedAssets)
    {
        _enforceReserve();

        if (deploymentPaused || _hasPendingWithdrawals()) {
            return 0;
        }

        if (deploymentInterval > 0) {
            uint256 nextAllowed = lastDeploymentAt + deploymentInterval;
            if (block.timestamp < nextAllowed) revert DeploymentTooSoon(nextAllowed);
        }

        lastDeploymentAt = block.timestamp;
        deployedAssets = _rebalanceAndAllocate(maxDeploymentAmount);
        emit DeploymentExecuted(deployedAssets, block.timestamp);
    }

    function processQueuedWithdrawals()
        external
        whenNotPaused
        nonReentrant
        returns (uint256 assetsPaid)
    {
        _enforceReserve();
        uint256 epochId = getCurrentEpoch();
        if (epochId > 0) {
            epochId -= 1;
        }
        assetsPaid = _processWithdrawals(epochId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ADMIN FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function setDepositFee(uint16 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps, MAX_FEE_BPS);
        emit DepositFeeUpdated(depositFeeBps, feeBps);
        depositFeeBps = feeBps;
    }

    function setWithdrawFee(uint16 feeBps) external onlyOwner {
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh(feeBps, MAX_FEE_BPS);
        emit WithdrawFeeUpdated(withdrawFeeBps, feeBps);
        withdrawFeeBps = feeBps;
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidTreasury();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    function setEpochLength(uint256 newLength) external onlyOwner {
        if (newLength == 0) revert InvalidAmount();
        epochLength = newLength;
    }

    function setReserveConfig(uint16 floorBps, uint16 targetBps, uint16 ceilBps) external onlyOwner {
        if (floorBps > targetBps || targetBps > ceilBps || ceilBps > BPS_DENOMINATOR) {
            revert ReserveConfigInvalid();
        }
        reserveFloorBps = floorBps;
        reserveTargetBps = targetBps;
        reserveCeilBps = ceilBps;
        emit ReserveConfigUpdated(floorBps, targetBps, ceilBps);
    }

    function setCoreDepositor(address newCoreDepositor) external onlyOwner {
        if (newCoreDepositor == address(0)) revert ZeroAddress();
        emit CoreDepositorUpdated(coreDepositor, newCoreDepositor);
        coreDepositor = newCoreDepositor;
    }

    function setDeploymentConfig(uint256 interval, uint256 maxBatchAmount) external onlyOwner {
        deploymentInterval = interval;
        maxDeploymentAmount = maxBatchAmount;
        emit DeploymentConfigUpdated(interval, maxBatchAmount);
    }

    function setDeploymentOperator(address operator) external onlyOwner {
        emit DeploymentOperatorUpdated(deploymentOperator, operator);
        deploymentOperator = operator;
    }

    function setPerpsConfig(uint32 dexIndex, uint64 tokenId, uint64 tokenScale, address subAccount) external onlyOwner {
        if (tokenScale == 0) revert InvalidAmount();
        perpDexIndex = dexIndex;
        perpsUsdcTokenId = tokenId;
        perpsUsdcScale = tokenScale;
        perpsSubAccount = subAccount;
    }

    function setDeploymentPaused(bool paused_) external onlyOwner {
        deploymentPaused = paused_;
        emit DeploymentPaused(paused_);
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function recoverTokens(address token, address to) external onlyOwner returns (uint256 recovered) {
        if (to == address(0)) revert ZeroAddress();
        if (token == asset()) {
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 reserved = totalPendingDeposits + pendingWithdrawalAssets;
            recovered = balance > reserved ? balance - reserved : 0;
        } else {
            recovered = IERC20(token).balanceOf(address(this));
        }
        if (recovered > 0) {
            IERC20(token).safeTransfer(to, recovered);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _availableL1() internal view returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        return idle > totalPendingDeposits ? idle - totalPendingDeposits : 0;
    }

    function _erc4626TVL() internal view returns (uint256 tvl) {
        for (uint256 i = 0; i < _strategies.length; i++) {
            Strategy memory strategy = _strategies[i];
            if (!strategy.active || strategy.strategyType != StrategyType.ERC4626) continue;
            tvl += IVaultAdapter(strategy.adapter).getTVL();
        }
    }

    function _erc4626Withdrawable() internal view returns (uint256 withdrawable) {
        for (uint256 i = 0; i < _strategies.length; i++) {
            Strategy memory strategy = _strategies[i];
            if (!strategy.active || strategy.strategyType != StrategyType.ERC4626) continue;
            try IVaultAdapter(strategy.adapter).maxWithdraw() returns (uint256 maxNow) {
                withdrawable += maxNow;
            } catch {}
        }
    }

    function _vaultTVL() internal view returns (uint256 tvl) {
        for (uint256 i = 0; i < _strategies.length; i++) {
            Strategy memory strategy = _strategies[i];
            if (!strategy.active || strategy.strategyType != StrategyType.VAULT) continue;
            tvl += IVaultAdapter(strategy.adapter).getTVL();
        }
    }

    function _perpsBalance() internal view returns (int256) {
        return HyperCoreReadPrecompile.getPerpsUsdcBalance(perpDexIndex, address(this));
    }

    function _getWithdrawableLiquidity() internal view returns (uint256) {
        return _availableL1() + _erc4626Withdrawable();
    }

    function _applySignedBalance(uint256 base, int256 delta) internal pure returns (uint256) {
        if (delta >= 0) {
            // casting to uint256 is safe because delta is non-negative here
            // forge-lint: disable-next-line(unsafe-typecast)
            return base + uint256(delta);
        }
        // casting to uint256 is safe because -delta is non-negative here
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 absDelta = uint256(-delta);
        return base > absDelta ? base - absDelta : 0;
    }

    function _applyPendingWithdrawals(uint256 total) internal view returns (uint256) {
        if (pendingWithdrawalAssets == 0) return total;
        return total > pendingWithdrawalAssets ? total - pendingWithdrawalAssets : 0;
    }

    function _calculateFee(uint256 assets, uint16 feeBps) internal pure returns (uint256) {
        if (feeBps == 0) return 0;
        return Math.mulDiv(assets, feeBps, BPS_DENOMINATOR);
    }

    function _applyFee(uint256 assets, uint16 feeBps) internal pure returns (uint256) {
        uint256 fee = _calculateFee(assets, feeBps);
        return assets - fee;
    }

    function _collectFee(uint256 fee) internal {
        if (fee == 0) return;
        IERC20(asset()).safeTransfer(treasury, fee);
        emit FeesCollected(treasury, fee);
    }

    function _processWithdrawals(uint256 epochId) internal returns (uint256 totalPaid) {
        uint256 availableLiquidity = _getWithdrawableLiquidity();
        if (availableLiquidity == 0) return 0;

        uint256 idx = withdrawalQueueHead;
        uint256 length = _withdrawalQueue.length;
        uint256 totalAssetsToPay;

        while (idx < length) {
            WithdrawalRequest memory request = _withdrawalQueue[idx];
            if (request.epoch > epochId) break;
            if (availableLiquidity < request.assets) break;

            availableLiquidity -= request.assets;
            totalAssetsToPay += request.assets;
            idx++;
        }

        if (totalAssetsToPay == 0) return 0;

        _prepareLiquidity(totalAssetsToPay);

        uint256 processedAssets;
        for (uint256 i = withdrawalQueueHead; i < idx; i++) {
            WithdrawalRequest memory request = _withdrawalQueue[i];
            uint256 fee = _calculateFee(request.assets, withdrawFeeBps);
            uint256 netAssets = request.assets - fee;

            IERC20(asset()).safeTransfer(request.receiver, netAssets);
            _collectFee(fee);

            totalPaid += request.assets;
            processedAssets += request.assets;
            emit WithdrawalProcessed(request.owner, request.receiver, request.assets, fee, request.epoch);
        }

        withdrawalQueueHead = idx;
        if (processedAssets > 0) {
            pendingWithdrawalAssets = pendingWithdrawalAssets > processedAssets
                ? pendingWithdrawalAssets - processedAssets
                : 0;
        }
        return totalPaid;
    }

    function _prepareLiquidity(uint256 totalAssetsToPay) internal {
        uint256 availableL1 = _availableL1();
        if (availableL1 >= totalAssetsToPay) return;

        uint256 remaining = totalAssetsToPay - availableL1;
        remaining = _withdrawFromERC4626(remaining);

        uint256 newAvailable = _availableL1();
        if (newAvailable < totalAssetsToPay) {
            revert InsufficientWithdrawableLiquidity(totalAssetsToPay, newAvailable);
        }
    }

    function _withdrawFromERC4626(uint256 amount) internal returns (uint256 remaining) {
        remaining = amount;
        for (uint256 i = 0; i < _strategies.length; i++) {
            if (remaining == 0) break;
            Strategy memory strategy = _strategies[i];
            if (!strategy.active || strategy.strategyType != StrategyType.ERC4626) continue;

            IVaultAdapter adapter = IVaultAdapter(strategy.adapter);
            uint256 maxNow = adapter.maxWithdraw();
            if (maxNow == 0) continue;

            uint256 toWithdraw = remaining > maxNow ? maxNow : remaining;
            if (toWithdraw == 0) continue;

            address receiptToken = adapter.getReceiptToken();
            if (receiptToken != address(0)) {
                uint256 sharesBalance = IERC20(receiptToken).balanceOf(address(this));
                if (sharesBalance == 0) continue;

                uint256 maxByShares = IERC4626(receiptToken).previewRedeem(sharesBalance);
                if (maxByShares < toWithdraw) {
                    toWithdraw = maxByShares;
                }
                if (toWithdraw == 0) continue;

                uint256 sharesNeeded = IERC4626(receiptToken).previewWithdraw(toWithdraw);
                if (sharesNeeded > sharesBalance) {
                    toWithdraw = IERC4626(receiptToken).previewRedeem(sharesBalance);
                    sharesNeeded = IERC4626(receiptToken).previewWithdraw(toWithdraw);
                }
                if (sharesNeeded > 0) {
                    IERC20(receiptToken).safeTransfer(strategy.adapter, sharesNeeded);
                }
            }

            try adapter.withdraw(toWithdraw) returns (uint256 actual) {
                if (actual == 0) revert AdapterOperationFailed(strategy.adapter);
                if (actual >= remaining) {
                    remaining = 0;
                } else {
                    remaining -= actual;
                }
            } catch {
                revert AdapterOperationFailed(strategy.adapter);
            }
        }
    }

    function _sendPerpsToEvm(uint256 amount) internal {
        int256 perpsBalance = _perpsBalance();
        if (perpsBalance <= 0) return;

        // casting to uint256 is safe because perpsBalance > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 available = uint256(perpsBalance);
        uint256 toSend = amount > available ? available : amount;
        if (toSend == 0) return;

        uint64 scaled = _scaleUsdcToPerps(toSend);
        HyperCoreWritePrecompile.sendAsset(
            address(this),
            perpsSubAccount,
            perpDexIndex,
            HyperCoreWritePrecompile.SPOT_DEX,
            perpsUsdcTokenId,
            scaled
        );
    }

    function _depositToERC4626(address adapter, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(asset()).safeTransfer(adapter, amount);
        try IVaultAdapter(adapter).deposit(amount) {} catch {
            revert AdapterOperationFailed(adapter);
        }
    }

    function _depositToPerps(uint256 amount) internal {
        if (amount == 0) return;
        IERC20(asset()).safeIncreaseAllowance(coreDepositor, amount);
        ICoreDepositor(coreDepositor).deposit(amount, perpDexIndex);
    }

    function _depositToVault(address adapter, uint256 amount) internal {
        if (amount == 0) return;
        uint64 scaled = HyperCoreWritePrecompile.scaleUSDCToCore(amount);
        address vault = IVaultAdapter(adapter).underlyingProtocol();
        HyperCoreWritePrecompile.vaultTransfer(vault, true, scaled);
    }

    function _withdrawFromVault(address adapter, uint256 amount) internal returns (uint256) {
        uint256 maxNow = IVaultAdapter(adapter).maxWithdraw();
        if (maxNow == 0) return 0;
        uint256 toWithdraw = amount > maxNow ? maxNow : amount;
        if (toWithdraw == 0) return 0;
        uint64 scaled = HyperCoreWritePrecompile.scaleUSDCToCore(toWithdraw);
        address vault = IVaultAdapter(adapter).underlyingProtocol();
        HyperCoreWritePrecompile.vaultTransfer(vault, false, scaled);
        return toWithdraw;
    }

    function _rebalanceAndAllocate(uint256 maxL1Deployable) internal returns (uint256 deployed) {
        if (_strategies.length == 0) return 0;

        uint256 total = totalAssets();
        uint256 reserveTarget = Math.mulDiv(total, reserveTargetBps, BPS_DENOMINATOR);
        uint256 deployable = total > reserveTarget ? total - reserveTarget : 0;

        Strategy[] memory strategies = _strategies;
        uint256[] memory targets = StrategyLib.calculateTargetAmounts(deployable, strategies);
        uint256[] memory currents = _currentStrategyAmounts(strategies);

        uint256 l1Available = _availableL1();
        uint256 l1Deployable = l1Available > reserveTarget ? l1Available - reserveTarget : 0;
        if (maxL1Deployable > 0 && l1Deployable > maxL1Deployable) {
            l1Deployable = maxL1Deployable;
        }
        uint256 perpsAdded;

        for (uint256 i = 0; i < strategies.length; i++) {
            if (!strategies[i].active) continue;
            if (strategies[i].strategyType == StrategyType.ERC4626 && targets[i] > currents[i]) {
                uint256 deficit = targets[i] - currents[i];
                uint256 toDeploy = deficit > l1Deployable ? l1Deployable : deficit;
                if (toDeploy > 0) {
                    _depositToERC4626(strategies[i].adapter, toDeploy);
                    l1Deployable -= toDeploy;
                    deployed += toDeploy;
                }
            }
            if (strategies[i].strategyType == StrategyType.PERPS && targets[i] > currents[i]) {
                uint256 deficit = targets[i] - currents[i];
                uint256 toDeploy = deficit > l1Deployable ? l1Deployable : deficit;
                if (toDeploy > 0) {
                    _depositToPerps(toDeploy);
                    perpsAdded += toDeploy;
                    l1Deployable -= toDeploy;
                    deployed += toDeploy;
                }
            }
        }

        // casting to uint256 is safe because perpsBalance is checked > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 perpsBalanceSnapshot = _perpsBalance();
        uint256 perpsCurrent = perpsBalanceSnapshot > 0 ? uint256(perpsBalanceSnapshot) : 0;
        uint256 perpsTarget = _findPerpsTarget(strategies, targets);
        uint256 perpsProjected = perpsCurrent + perpsAdded;
        uint256 perpsExcess = perpsProjected > perpsTarget ? perpsProjected - perpsTarget : 0;

        for (uint256 i = 0; i < strategies.length; i++) {
            if (!strategies[i].active || strategies[i].strategyType != StrategyType.VAULT) continue;
            if (targets[i] <= currents[i]) continue;

            uint256 deficit = targets[i] - currents[i];
            uint256 toDeploy = deficit > perpsExcess ? perpsExcess : deficit;
            if (toDeploy == 0) continue;

            _depositToVault(strategies[i].adapter, toDeploy);
            perpsExcess -= toDeploy;
            if (perpsExcess == 0) break;
        }
        return deployed;
    }

    function _currentStrategyAmounts(Strategy[] memory strategies) internal view returns (uint256[] memory amounts) {
        amounts = new uint256[](strategies.length);
        int256 perpsBalance = _perpsBalance();
        // casting to uint256 is safe because perpsBalance is checked > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 perpsPositive = perpsBalance > 0 ? uint256(perpsBalance) : 0;

        for (uint256 i = 0; i < strategies.length; i++) {
            if (!strategies[i].active) {
                amounts[i] = 0;
                continue;
            }

            if (strategies[i].strategyType == StrategyType.PERPS) {
                amounts[i] = perpsPositive;
            } else {
                amounts[i] = IVaultAdapter(strategies[i].adapter).getTVL();
            }
        }
    }

    function _findPerpsTarget(Strategy[] memory strategies, uint256[] memory targets) internal pure returns (uint256) {
        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i].active && strategies[i].strategyType == StrategyType.PERPS) {
                return targets[i];
            }
        }
        return 0;
    }

    function _enforceReserve() internal {
        uint256 total = totalAssets();
        if (total == 0) return;

        uint256 withdrawable = _getWithdrawableLiquidity();
        uint256 floorAmount = Math.mulDiv(total, reserveFloorBps, BPS_DENOMINATOR);
        uint256 ceilAmount = Math.mulDiv(total, reserveCeilBps, BPS_DENOMINATOR);

        if (withdrawable < floorAmount) {
            if (!deploymentPaused) {
                deploymentPaused = true;
                emit DeploymentPaused(true);
            }
            uint256 deficit = floorAmount - withdrawable;
            _recallFromVaults(deficit);
            _sendPerpsToEvm(deficit);
        } else if (withdrawable > ceilAmount && deploymentPaused) {
            deploymentPaused = false;
            emit DeploymentPaused(false);
        }
    }

    function _recallFromVaults(uint256 amountNeeded) internal {
        if (amountNeeded == 0) return;
        uint256 remaining = amountNeeded;

        for (uint256 i = 0; i < _strategies.length; i++) {
            if (remaining == 0) break;
            Strategy memory strategy = _strategies[i];
            if (!strategy.active || strategy.strategyType != StrategyType.VAULT) continue;

            uint256 withdrawn = _withdrawFromVault(strategy.adapter, remaining);
            if (withdrawn >= remaining) {
                remaining = 0;
            } else {
                remaining -= withdrawn;
            }
        }
    }

    function _hasPendingWithdrawals() internal view returns (bool) {
        return withdrawalQueueHead < _withdrawalQueue.length;
    }

    function _scaleUsdcToPerps(uint256 amount) internal view returns (uint64) {
        uint256 scaled = Math.mulDiv(amount, perpsUsdcScale, USDC_DECIMALS);
        if (scaled > type(uint64).max) revert InvalidAmount();
        // casting to uint64 is safe because overflow checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(scaled);
    }
}
