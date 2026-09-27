// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {CommitRevealVote} from "../src/CommitRevealVote.sol";

/// @title Deploy
/// @notice Deploys one `CommitRevealVote` with the documented demo schedule.
///
/// The script reads exactly one environment variable, `EXPECTED_CHAIN_ID`. A non-zero value must
/// match the chain the script is executing against; `0` skips that pin (offline dry run). On every
/// path the chain must be one of the allowed targets (Anvil 31337 or Sepolia 11155111). The script
/// never reads a private key or an RPC URL: the operator supplies those on the `forge script`
/// command line, and only the network's own deployer does so.
///
/// `run()` is the entry point for `forge script`. It builds a `Config` and hands it to `deploy`,
/// which tests call directly with their own config so no test touches the shared environment.
contract Deploy is Script {
    /// @notice Demo commit window: 2 days.
    uint256 public constant DEMO_COMMIT_DURATION = 2 days;
    /// @notice Demo reveal window: 2 days.
    uint256 public constant DEMO_REVEAL_DURATION = 2 days;

    uint256 public constant ANVIL_CHAIN_ID = 31337;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;

    error UnexpectedChainId(uint256 expected, uint256 actual);
    error ChainNotAllowed(uint256 chainId);

    struct Config {
        uint256 expectedChainId;
        uint256 commitDuration;
        uint256 revealDuration;
    }

    function run() external returns (CommitRevealVote vote) {
        Config memory config = Config({
            expectedChainId: vm.envUint("EXPECTED_CHAIN_ID"),
            commitDuration: DEMO_COMMIT_DURATION,
            revealDuration: DEMO_REVEAL_DURATION
        });
        vote = deploy(config);
    }

    /// @notice Validate the chain and deploy exactly one contract between the broadcast markers.
    /// @dev `expectedChainId == 0` means "no pinned expectation" (used by the offline dry run); the
    ///      allow-list below still applies, so mainnet is refused on every path.
    function deploy(Config memory config) public returns (CommitRevealVote vote) {
        if (config.expectedChainId != 0 && config.expectedChainId != block.chainid) {
            revert UnexpectedChainId(config.expectedChainId, block.chainid);
        }
        if (block.chainid != ANVIL_CHAIN_ID && block.chainid != SEPOLIA_CHAIN_ID) {
            revert ChainNotAllowed(block.chainid);
        }

        vm.startBroadcast();
        vote = new CommitRevealVote(config.commitDuration, config.revealDuration);
        vm.stopBroadcast();
    }
}
