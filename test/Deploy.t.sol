// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {CommitRevealVote} from "../src/CommitRevealVote.sol";

/// @dev Exercises the deploy script's `deploy(config)` directly. No test reads or writes the
///      process environment, so the suite stays safe to run in parallel.
contract DeployTest is Test {
    Deploy internal script;

    function setUp() public {
        script = new Deploy();
    }

    function _config(uint256 chainId) internal pure returns (Deploy.Config memory) {
        return Deploy.Config({expectedChainId: chainId, commitDuration: 2 days, revealDuration: 2 days});
    }

    function test_deploysOnAnvilWithDemoSchedule() public {
        vm.chainId(31337);
        vm.warp(1_700_000_000);
        CommitRevealVote vote = script.deploy(_config(31337));
        assertTrue(address(vote).code.length > 0);
        assertEq(vote.commitEnd(), 1_700_000_000 + 2 days);
        assertEq(vote.revealEnd(), 1_700_000_000 + 4 days);
    }

    function test_deploysOnSepolia() public {
        vm.chainId(11155111);
        CommitRevealVote vote = script.deploy(_config(11155111));
        assertTrue(address(vote).code.length > 0);
        assertEq(uint8(vote.outcome()), uint8(CommitRevealVote.Outcome.Pending));
    }

    function test_demoConstantsMatchConfig() public view {
        assertEq(script.DEMO_COMMIT_DURATION(), 2 days);
        assertEq(script.DEMO_REVEAL_DURATION(), 2 days);
        assertEq(script.SEPOLIA_CHAIN_ID(), 11155111);
        assertEq(script.ANVIL_CHAIN_ID(), 31337);
    }

    function test_refusesWhenExpectedChainIdDiffers() public {
        vm.chainId(11155111);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedChainId.selector, 31337, 11155111));
        script.deploy(_config(31337));
    }

    function test_zeroExpectedChainIdSkipsPinButKeepsAllowList() public {
        vm.chainId(31337);
        CommitRevealVote vote = script.deploy(_config(0));
        assertTrue(address(vote).code.length > 0);

        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainNotAllowed.selector, 1));
        script.deploy(_config(0));
    }

    function test_refusesMainnetEvenWhenExpected() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainNotAllowed.selector, 1));
        script.deploy(_config(1));
    }

    function testFuzz_refusesAnyDisallowedChain(uint64 chainId) public {
        vm.assume(chainId != 31337 && chainId != 11155111);
        vm.chainId(chainId);
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainNotAllowed.selector, uint256(chainId)));
        script.deploy(_config(chainId));
    }

    function testFuzz_refusesMismatchedPin(uint64 expected) public {
        vm.assume(expected != 0 && expected != 11155111);
        vm.chainId(11155111);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedChainId.selector, uint256(expected), 11155111));
        script.deploy(_config(expected));
    }
}
