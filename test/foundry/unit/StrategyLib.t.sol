// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "../BaseTest.sol";
import {StrategyLib} from "../../../contracts/libraries/StrategyLib.sol";
import {StrategyType, StrategyInput, Strategy} from "../../../contracts/types/VaultTypes.sol";

contract StrategyLibTest is BaseTest {
    address adapter1;
    address adapter2;

    StrategyLibWrapper wrapper;

    function setUp() public override {
        super.setUp();
        adapter1 = makeAddr("adapter1");
        adapter2 = makeAddr("adapter2");
        wrapper = new StrategyLibWrapper();
    }

    function test_validateStrategies_valid() public view {
        StrategyInput[] memory inputs = new StrategyInput[](3);
        inputs[0] = StrategyInput({
            adapter: adapter1,
            targetBps: 4000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        inputs[1] = StrategyInput({
            adapter: address(0),
            targetBps: 3000,
            strategyType: StrategyType.PERPS,
            active: true
        });
        inputs[2] = StrategyInput({
            adapter: adapter2,
            targetBps: 3000,
            strategyType: StrategyType.VAULT,
            active: true
        });

        uint16 totalBps = wrapper.validateStrategyInputs(inputs);
        assertEq(totalBps, 10_000, "total should be 100%");
    }

    function test_validateStrategies_invalidSum() public {
        StrategyInput[] memory inputs = new StrategyInput[](2);
        inputs[0] = StrategyInput({
            adapter: adapter1,
            targetBps: 5000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        inputs[1] = StrategyInput({
            adapter: adapter2,
            targetBps: 3000,
            strategyType: StrategyType.VAULT,
            active: true
        });

        vm.expectRevert(abi.encodeWithSelector(StrategyLib.InvalidAllocationSum.selector, 8000, 10_000));
        wrapper.validateStrategyInputs(inputs);
    }

    function test_validateStrategies_invalidPerpsAdapter() public {
        StrategyInput[] memory inputs = new StrategyInput[](1);
        inputs[0] = StrategyInput({
            adapter: adapter1,
            targetBps: 10_000,
            strategyType: StrategyType.PERPS,
            active: true
        });

        vm.expectRevert(StrategyLib.InvalidPerpsStrategy.selector);
        wrapper.validateStrategyInputs(inputs);
    }

    function test_validateStrategies_duplicateAdapter() public {
        StrategyInput[] memory inputs = new StrategyInput[](2);
        inputs[0] = StrategyInput({
            adapter: adapter1,
            targetBps: 5000,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        inputs[1] = StrategyInput({
            adapter: adapter1,
            targetBps: 5000,
            strategyType: StrategyType.VAULT,
            active: true
        });

        vm.expectRevert(abi.encodeWithSelector(StrategyLib.DuplicateStrategy.selector, adapter1));
        wrapper.validateStrategyInputs(inputs);
    }

    function test_calculateTargetAmounts_handlesRounding() public view {
        Strategy[] memory strategies = new Strategy[](2);
        strategies[0] = Strategy({
            adapter: adapter1,
            targetBps: 3333,
            strategyType: StrategyType.ERC4626,
            active: true
        });
        strategies[1] = Strategy({
            adapter: adapter2,
            targetBps: 6667,
            strategyType: StrategyType.VAULT,
            active: true
        });

        uint256[] memory targets = wrapper.calculateTargetAmounts(1_000_000, strategies);
        assertEq(targets.length, 2);
        assertEq(targets[0] + targets[1], 1_000_000, "total should match");
    }

    function test_bpsToPercentage() public pure {
        (uint16 whole, uint16 decimal) = StrategyLib.bpsToPercentage(1234);
        assertEq(whole, 12);
        assertEq(decimal, 34);
    }
}

contract StrategyLibWrapper {
    function validateStrategyInputs(
        StrategyInput[] calldata inputs
    ) external pure returns (uint16 totalBps) {
        return StrategyLib.validateStrategyInputs(inputs);
    }

    function calculateTargetAmounts(
        uint256 deployableAssets,
        Strategy[] memory strategies
    ) external pure returns (uint256[] memory) {
        return StrategyLib.calculateTargetAmounts(deployableAssets, strategies);
    }
}
