// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CommitRevealVote} from "../src/CommitRevealVote.sol";

contract CommitRevealVoteTest is Test {
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant COMMIT_DURATION = 1 days;
    uint256 internal constant REVEAL_DURATION = 12 hours;

    CommitRevealVote internal vote;
    uint256 internal commitEnd;
    uint256 internal revealEnd;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal anyone = makeAddr("anyone");

    bytes32 internal constant SALT_A = keccak256("salt-a");
    bytes32 internal constant SALT_B = keccak256("salt-b");
    bytes32 internal constant SALT_C = keccak256("salt-c");
    bytes32 internal constant SALT_D = keccak256("salt-d");

    event Committed(address indexed voter, bytes32 commitment);
    event Revealed(address indexed voter, uint8 option);
    event Finalized(CommitRevealVote.Outcome outcome, uint8 winningOption, uint256 totalRevealed);

    function setUp() public {
        vm.warp(START);
        vote = new CommitRevealVote(COMMIT_DURATION, REVEAL_DURATION);
        commitEnd = START + COMMIT_DURATION;
        revealEnd = commitEnd + REVEAL_DURATION;
    }

    // ------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------

    function _commitAs(address voter, uint8 option, bytes32 salt) internal {
        bytes32 c = vote.computeCommitment(voter, option, salt);
        vm.prank(voter);
        vote.commit(c);
    }

    function _revealAs(address voter, uint8 option, bytes32 salt) internal {
        vm.prank(voter);
        vote.reveal(option, salt);
    }

    function _enterRevealPhase() internal {
        vm.warp(commitEnd);
    }

    function _enterFinalPhase() internal {
        vm.warp(revealEnd);
    }

    function _voter(uint256 i) internal pure returns (address) {
        return address(uint160(0x1000 + i));
    }

    function _saltFor(uint256 i) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", i));
    }

    function _optionFor(uint256 i, uint8 n0, uint8 n1) internal pure returns (uint8) {
        if (i < n0) return 0;
        if (i < uint256(n0) + n1) return 1;
        return 2;
    }

    // ------------------------------------------------------------------------------------------
    // Construction
    // ------------------------------------------------------------------------------------------

    function test_constructorSetsSchedule() public view {
        assertEq(vote.commitEnd(), commitEnd);
        assertEq(vote.revealEnd(), revealEnd);
        assertEq(uint8(vote.outcome()), uint8(CommitRevealVote.Outcome.Pending));
        assertEq(vote.totalRevealed(), 0);
        assertEq(vote.OPTION_COUNT(), 3);
        assertTrue(vote.isCommitPhase());
        assertFalse(vote.isRevealPhase());
        assertFalse(vote.isFinalizable());
    }

    function test_constructorRejectsZeroCommitDuration() public {
        vm.expectRevert(CommitRevealVote.InvalidSchedule.selector);
        new CommitRevealVote(0, 1);
    }

    function test_constructorRejectsZeroRevealDuration() public {
        vm.expectRevert(CommitRevealVote.InvalidSchedule.selector);
        new CommitRevealVote(1, 0);
    }

    function test_commitmentBindsChainIdContractVoterOptionSalt() public view {
        bytes32 expected = keccak256(abi.encode(block.chainid, address(vote), alice, uint8(1), SALT_A));
        assertEq(vote.computeCommitment(alice, 1, SALT_A), expected);
    }

    function test_commitmentDiffersAcrossChainIds() public {
        bytes32 here = vote.computeCommitment(alice, 1, SALT_A);
        vm.chainId(11155111);
        bytes32 there = vote.computeCommitment(alice, 1, SALT_A);
        assertTrue(here != there, "commitment must depend on chain id");
    }

    function test_commitmentDiffersAcrossContracts() public {
        CommitRevealVote other = new CommitRevealVote(COMMIT_DURATION, REVEAL_DURATION);
        assertTrue(
            vote.computeCommitment(alice, 1, SALT_A) != other.computeCommitment(alice, 1, SALT_A),
            "commitment must depend on contract address"
        );
    }

    // ------------------------------------------------------------------------------------------
    // Commit
    // ------------------------------------------------------------------------------------------

    function test_commitStoresCommitmentAndEmits() public {
        bytes32 c = vote.computeCommitment(alice, 2, SALT_A);
        vm.expectEmit(true, false, false, true, address(vote));
        emit Committed(alice, c);
        vm.prank(alice);
        vote.commit(c);
        assertEq(vote.commitmentOf(alice), c);
        assertFalse(vote.hasRevealed(alice));
    }

    function test_commitRejectsZeroCommitment() public {
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.EmptyCommitment.selector);
        vote.commit(bytes32(0));
    }

    function test_commitRejectsSecondCommitmentFromSameAddress() public {
        _commitAs(alice, 0, SALT_A);
        bytes32 other = vote.computeCommitment(alice, 1, SALT_B);
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.AlreadyCommitted.selector);
        vote.commit(other);
        // The original commitment is untouched.
        assertEq(vote.commitmentOf(alice), vote.computeCommitment(alice, 0, SALT_A));
    }

    function test_commitAllowedUntilLastSecondOfCommitPhase() public {
        vm.warp(commitEnd - 1);
        _commitAs(alice, 0, SALT_A);
        assertEq(vote.commitmentOf(alice), vote.computeCommitment(alice, 0, SALT_A));
    }

    function test_commitRejectedExactlyAtCommitEnd() public {
        vm.warp(commitEnd);
        bytes32 c = vote.computeCommitment(alice, 0, SALT_A);
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.CommitPhaseOver.selector);
        vote.commit(c);
    }

    function test_commitRejectedAfterRevealEnd() public {
        vm.warp(revealEnd + 1);
        bytes32 c = vote.computeCommitment(alice, 0, SALT_A);
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.CommitPhaseOver.selector);
        vote.commit(c);
    }

    // ------------------------------------------------------------------------------------------
    // Reveal
    // ------------------------------------------------------------------------------------------

    function test_revealHappyPathTalliesAndEmits() public {
        _commitAs(alice, 2, SALT_A);
        _enterRevealPhase();

        vm.expectEmit(true, false, false, true, address(vote));
        emit Revealed(alice, 2);
        _revealAs(alice, 2, SALT_A);

        assertTrue(vote.hasRevealed(alice));
        assertEq(vote.tally(2), 1);
        assertEq(vote.tally(0), 0);
        assertEq(vote.tally(1), 0);
        assertEq(vote.totalRevealed(), 1);
    }

    function test_revealRejectedBeforeCommitEnd() public {
        _commitAs(alice, 0, SALT_A);
        vm.warp(commitEnd - 1);
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.NotRevealPhase.selector);
        vote.reveal(0, SALT_A);
    }

    function test_revealAllowedExactlyAtCommitEnd() public {
        _commitAs(alice, 0, SALT_A);
        vm.warp(commitEnd);
        _revealAs(alice, 0, SALT_A);
        assertEq(vote.tally(0), 1);
    }

    function test_revealAllowedAtLastSecondOfRevealPhase() public {
        _commitAs(alice, 1, SALT_A);
        vm.warp(revealEnd - 1);
        _revealAs(alice, 1, SALT_A);
        assertEq(vote.tally(1), 1);
    }

    function test_revealRejectedExactlyAtRevealEnd() public {
        _commitAs(alice, 1, SALT_A);
        vm.warp(revealEnd);
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.NotRevealPhase.selector);
        vote.reveal(1, SALT_A);
    }

    function test_revealRejectsWrongSalt() public {
        _commitAs(alice, 1, SALT_A);
        _enterRevealPhase();
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.CommitmentMismatch.selector);
        vote.reveal(1, SALT_B);
        assertFalse(vote.hasRevealed(alice));
        assertEq(vote.totalRevealed(), 0);
    }

    function test_revealRejectsWrongOptionForCommitment() public {
        _commitAs(alice, 1, SALT_A);
        _enterRevealPhase();
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.CommitmentMismatch.selector);
        vote.reveal(2, SALT_A);
    }

    function test_revealRejectsWrongCaller() public {
        // Bob knows Alice's option and salt but the hash binds Alice's address.
        _commitAs(alice, 1, SALT_A);
        _enterRevealPhase();
        vm.prank(bob);
        vm.expectRevert(CommitRevealVote.NoCommitment.selector);
        vote.reveal(1, SALT_A);

        // Even if Bob has his own commitment, Alice's secrets do not match it.
        vm.warp(commitEnd - 1);
        _commitAs(bob, 0, SALT_B);
        _enterRevealPhase();
        vm.prank(bob);
        vm.expectRevert(CommitRevealVote.CommitmentMismatch.selector);
        vote.reveal(1, SALT_A);
        assertEq(vote.totalRevealed(), 0);
    }

    function test_revealRejectsAddressWithoutCommitment() public {
        _enterRevealPhase();
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.NoCommitment.selector);
        vote.reveal(0, SALT_A);
    }

    function test_revealRejectsInvalidOption() public {
        // A voter who committed to option 3 can never reveal: the option check fires before the hash.
        _commitAs(alice, 3, SALT_A);
        _enterRevealPhase();
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.InvalidOption.selector);
        vote.reveal(3, SALT_A);
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.InvalidOption.selector);
        vote.reveal(type(uint8).max, SALT_A);
    }

    function test_revealRejectsDuplicateReveal() public {
        _commitAs(alice, 1, SALT_A);
        _enterRevealPhase();
        _revealAs(alice, 1, SALT_A);
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.AlreadyRevealed.selector);
        vote.reveal(1, SALT_A);
        assertEq(vote.tally(1), 1);
        assertEq(vote.totalRevealed(), 1);
    }

    function test_tallyViewRejectsInvalidOption() public {
        vm.expectRevert(CommitRevealVote.InvalidOption.selector);
        vote.tally(3);
    }

    // ------------------------------------------------------------------------------------------
    // Finalize
    // ------------------------------------------------------------------------------------------

    function test_finalizeRejectedBeforeRevealEnd() public {
        vm.warp(revealEnd - 1);
        vm.prank(anyone);
        vm.expectRevert(CommitRevealVote.RevealPhaseNotOver.selector);
        vote.finalize();
    }

    function test_finalizeRejectedDuringCommitPhase() public {
        vm.prank(anyone);
        vm.expectRevert(CommitRevealVote.RevealPhaseNotOver.selector);
        vote.finalize();
    }

    function test_finalizeIsPermissionlessAndAllowedExactlyAtRevealEnd() public {
        _commitAs(alice, 2, SALT_A);
        _enterRevealPhase();
        _revealAs(alice, 2, SALT_A);
        vm.warp(revealEnd);

        vm.expectEmit(false, false, false, true, address(vote));
        emit Finalized(CommitRevealVote.Outcome.Decided, 2, 1);
        vm.prank(anyone);
        vote.finalize();

        assertEq(uint8(vote.outcome()), uint8(CommitRevealVote.Outcome.Decided));
        assertEq(vote.winningOption(), 2);
    }

    function test_finalizeRejectsSecondCall() public {
        _enterFinalPhase();
        vote.finalize();
        vm.expectRevert(CommitRevealVote.AlreadyFinalized.selector);
        vote.finalize();
    }

    function test_finalizeWithZeroRevealsGivesNoResult() public {
        // Commitments without reveals do not count.
        _commitAs(alice, 0, SALT_A);
        _commitAs(bob, 1, SALT_B);
        _enterFinalPhase();

        vm.expectEmit(false, false, false, true, address(vote));
        emit Finalized(CommitRevealVote.Outcome.NoResult, 0, 0);
        vm.prank(anyone);
        vote.finalize();

        assertEq(uint8(vote.outcome()), uint8(CommitRevealVote.Outcome.NoResult));
        assertEq(vote.totalRevealed(), 0);
        // NoResult is distinct from "option 0 won".
        assertTrue(vote.outcome() != CommitRevealVote.Outcome.Decided);
    }

    function test_finalizeSingleRevealForOptionZeroIsDecidedNotNoResult() public {
        _commitAs(alice, 0, SALT_A);
        _enterRevealPhase();
        _revealAs(alice, 0, SALT_A);
        _enterFinalPhase();
        vote.finalize();
        assertEq(uint8(vote.outcome()), uint8(CommitRevealVote.Outcome.Decided));
        assertEq(vote.winningOption(), 0);
    }

    function test_finalizeMajorityWins() public {
        _commitAs(alice, 1, SALT_A);
        _commitAs(bob, 1, SALT_B);
        _commitAs(carol, 2, SALT_C);
        _enterRevealPhase();
        _revealAs(alice, 1, SALT_A);
        _revealAs(bob, 1, SALT_B);
        _revealAs(carol, 2, SALT_C);
        _enterFinalPhase();
        vote.finalize();
        assertEq(vote.winningOption(), 1);
        uint256[3] memory t = vote.tallies();
        assertEq(t[0], 0);
        assertEq(t[1], 2);
        assertEq(t[2], 1);
    }

    function test_finalizeTieBetween1And2SelectsOption1() public {
        _commitAs(alice, 2, SALT_A);
        _commitAs(bob, 1, SALT_B);
        _enterRevealPhase();
        _revealAs(alice, 2, SALT_A);
        _revealAs(bob, 1, SALT_B);
        _enterFinalPhase();
        vote.finalize();
        assertEq(uint8(vote.outcome()), uint8(CommitRevealVote.Outcome.Decided));
        assertEq(vote.winningOption(), 1);
    }

    function test_finalizeTieBetween0And2SelectsOption0() public {
        _commitAs(alice, 2, SALT_A);
        _commitAs(bob, 0, SALT_B);
        _enterRevealPhase();
        _revealAs(alice, 2, SALT_A);
        _revealAs(bob, 0, SALT_B);
        _enterFinalPhase();
        vote.finalize();
        assertEq(vote.winningOption(), 0);
    }

    function test_finalizeThreeWayTieSelectsOption0() public {
        _commitAs(alice, 2, SALT_A);
        _commitAs(bob, 1, SALT_B);
        _commitAs(carol, 0, SALT_C);
        _enterRevealPhase();
        _revealAs(alice, 2, SALT_A);
        _revealAs(bob, 1, SALT_B);
        _revealAs(carol, 0, SALT_C);
        _enterFinalPhase();
        vote.finalize();
        assertEq(vote.winningOption(), 0);
    }

    function test_unrevealedCommitmentsDoNotCount() public {
        _commitAs(alice, 2, SALT_A);
        _commitAs(bob, 2, SALT_B);
        _commitAs(carol, 2, SALT_C);
        _commitAs(dave, 1, SALT_D);
        _enterRevealPhase();
        // Only Dave reveals: option 1 wins despite three commitments to option 2.
        _revealAs(dave, 1, SALT_D);
        _enterFinalPhase();
        vote.finalize();
        assertEq(vote.winningOption(), 1);
        assertEq(vote.totalRevealed(), 1);
    }

    function test_afterFinalizeCommitAndRevealStillRejected() public {
        _commitAs(alice, 1, SALT_A);
        _enterFinalPhase();
        vote.finalize();

        bytes32 c = vote.computeCommitment(bob, 0, SALT_B);
        vm.prank(bob);
        vm.expectRevert(CommitRevealVote.CommitPhaseOver.selector);
        vote.commit(c);

        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.NotRevealPhase.selector);
        vote.reveal(1, SALT_A);
    }

    // ------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------

    /// @dev A correct reveal always succeeds for any valid option and salt.
    function testFuzz_commitThenRevealSucceeds(address voter, uint8 option, bytes32 salt) public {
        vm.assume(voter != address(0));
        option = uint8(bound(option, 0, 2));
        _commitAs(voter, option, salt);
        _enterRevealPhase();
        _revealAs(voter, option, salt);
        assertTrue(vote.hasRevealed(voter));
        assertEq(vote.tally(option), 1);
        assertEq(vote.totalRevealed(), 1);
    }

    /// @dev Any salt other than the committed one is rejected.
    function testFuzz_revealWithWrongSaltFails(uint8 option, bytes32 salt, bytes32 wrongSalt) public {
        vm.assume(salt != wrongSalt);
        option = uint8(bound(option, 0, 2));
        _commitAs(alice, option, salt);
        _enterRevealPhase();
        vm.prank(alice);
        vm.expectRevert(CommitRevealVote.CommitmentMismatch.selector);
        vote.reveal(option, wrongSalt);
    }

    /// @dev Any option other than the committed one is rejected (with the right error class).
    function testFuzz_revealWithWrongOptionFails(uint8 option, uint8 wrongOption, bytes32 salt) public {
        option = uint8(bound(option, 0, 2));
        vm.assume(wrongOption != option);
        _commitAs(alice, option, salt);
        _enterRevealPhase();
        vm.prank(alice);
        if (wrongOption >= 3) {
            vm.expectRevert(CommitRevealVote.InvalidOption.selector);
        } else {
            vm.expectRevert(CommitRevealVote.CommitmentMismatch.selector);
        }
        vote.reveal(wrongOption, salt);
    }

    /// @dev Any address other than the committer is rejected.
    function testFuzz_revealByOtherCallerFails(address other, uint8 option, bytes32 salt) public {
        vm.assume(other != alice);
        option = uint8(bound(option, 0, 2));
        _commitAs(alice, option, salt);
        _enterRevealPhase();
        vm.prank(other);
        vm.expectRevert(CommitRevealVote.NoCommitment.selector);
        vote.reveal(option, salt);
    }

    /// @dev Phase gates hold for arbitrary timestamps.
    function testFuzz_phaseGates(uint256 t) public {
        t = bound(t, START, revealEnd + 365 days);
        _commitAs(alice, 0, SALT_A);
        vm.warp(t);

        bytes32 c = vote.computeCommitment(bob, 1, SALT_B);
        vm.prank(bob);
        if (t >= commitEnd) vm.expectRevert(CommitRevealVote.CommitPhaseOver.selector);
        vote.commit(c);

        vm.prank(alice);
        if (t < commitEnd || t >= revealEnd) vm.expectRevert(CommitRevealVote.NotRevealPhase.selector);
        vote.reveal(0, SALT_A);

        if (t < revealEnd) vm.expectRevert(CommitRevealVote.RevealPhaseNotOver.selector);
        vote.finalize();
    }

    /// @dev The winner is the argmax with lowest-index tie-break, for any distribution of votes.
    function testFuzz_winnerIsLowestArgmax(uint8 n0, uint8 n1, uint8 n2) public {
        n0 = uint8(bound(n0, 0, 6));
        n1 = uint8(bound(n1, 0, 6));
        n2 = uint8(bound(n2, 0, 6));

        uint256 total = uint256(n0) + n1 + n2;
        for (uint256 i = 0; i < total; ++i) {
            _commitAs(_voter(i), _optionFor(i, n0, n1), _saltFor(i));
        }

        _enterRevealPhase();
        for (uint256 i = 0; i < total; ++i) {
            _revealAs(_voter(i), _optionFor(i, n0, n1), _saltFor(i));
        }

        _enterFinalPhase();
        vote.finalize();

        assertEq(vote.totalRevealed(), total);
        if (total == 0) {
            assertEq(uint8(vote.outcome()), uint8(CommitRevealVote.Outcome.NoResult));
            return;
        }
        assertEq(uint8(vote.outcome()), uint8(CommitRevealVote.Outcome.Decided));

        uint8 expected = 0;
        uint256 best = n0;
        if (n1 > best) {
            expected = 1;
            best = n1;
        }
        if (n2 > best) {
            expected = 2;
        }
        assertEq(vote.winningOption(), expected);
    }
}
