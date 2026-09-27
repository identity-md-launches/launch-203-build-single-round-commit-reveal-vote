// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title CommitRevealVote
/// @notice A single-round commit–reveal vote among the options 0, 1 and 2.
///
/// Timeline (all comparisons use `block.timestamp`):
///   - commit phase:   `block.timestamp <  commitEnd`
///   - reveal phase:   `commitEnd <= block.timestamp < revealEnd`
///   - finalization:   `block.timestamp >= revealEnd`
///
/// A commitment is `keccak256(abi.encode(block.chainid, address(this), voter, option, salt))`.
/// Binding the chain id, the contract address and the voter means a commitment cannot be replayed
/// on another chain, on another instance of this contract, or by another address.
///
/// One commitment per address, no overwrite, no withdrawal. One reveal per address. Finalization is
/// permissionless and happens exactly once. Ties resolve to the lowest option number. If nobody
/// reveals, the vote finalizes into a distinct no-result state rather than declaring option 0.
///
/// This contract has no owner, no tokens, no randomness, and makes no claim of Sybil resistance:
/// every address is one vote and addresses are free.
contract CommitRevealVote {
    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice Outcome of the round once finalized.
    /// @dev `Pending` is the value before `finalize` has run. `NoResult` means zero reveals.
    enum Outcome {
        Pending,
        NoResult,
        Decided
    }

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error InvalidSchedule();
    error CommitPhaseOver();
    error NotRevealPhase();
    error RevealPhaseNotOver();
    error EmptyCommitment();
    error AlreadyCommitted();
    error NoCommitment();
    error AlreadyRevealed();
    error InvalidOption();
    error CommitmentMismatch();
    error AlreadyFinalized();

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event Committed(address indexed voter, bytes32 commitment);
    event Revealed(address indexed voter, uint8 option);
    event Finalized(Outcome outcome, uint8 winningOption, uint256 totalRevealed);

    // ---------------------------------------------------------------------------------------------
    // Constants and immutables
    // ---------------------------------------------------------------------------------------------

    /// @notice Number of options; valid options are `0 .. OPTION_COUNT - 1`.
    uint8 public constant OPTION_COUNT = 3;

    /// @notice First timestamp at which commits are rejected and reveals are accepted.
    uint256 public immutable commitEnd;

    /// @notice First timestamp at which reveals are rejected and finalization is accepted.
    uint256 public immutable revealEnd;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    /// @notice Commitment hash per voter; zero means "never committed".
    mapping(address voter => bytes32 commitment) public commitmentOf;

    /// @notice Whether a voter has already revealed.
    mapping(address voter => bool revealed) public hasRevealed;

    /// @notice Revealed vote counts, indexed by option.
    uint256[OPTION_COUNT] private _tally;

    /// @notice Total number of successful reveals.
    uint256 public totalRevealed;

    /// @notice Outcome after finalization; `Pending` until `finalize` runs.
    Outcome public outcome;

    /// @notice Winning option after finalization. Only meaningful when `outcome == Decided`.
    uint8 public winningOption;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param commitDuration Seconds from deployment during which commits are accepted. Must be > 0.
    /// @param revealDuration Seconds after `commitEnd` during which reveals are accepted. Must be > 0.
    /// @dev Durations rather than absolute timestamps so the same constructor arguments work
    ///      whenever the deployer (a factory, a script, a test) actually creates the contract.
    constructor(uint256 commitDuration, uint256 revealDuration) {
        if (commitDuration == 0 || revealDuration == 0) revert InvalidSchedule();
        uint256 commitEnd_ = block.timestamp + commitDuration;
        uint256 revealEnd_ = commitEnd_ + revealDuration;
        commitEnd = commitEnd_;
        revealEnd = revealEnd_;
    }

    // ---------------------------------------------------------------------------------------------
    // Commit
    // ---------------------------------------------------------------------------------------------

    /// @notice Store a commitment for `msg.sender`. Allowed once per address, only before `commitEnd`.
    /// @param commitment `computeCommitment(msg.sender, option, salt)`; must be non-zero.
    function commit(bytes32 commitment) external {
        if (block.timestamp >= commitEnd) revert CommitPhaseOver();
        if (commitment == bytes32(0)) revert EmptyCommitment();
        if (commitmentOf[msg.sender] != bytes32(0)) revert AlreadyCommitted();

        commitmentOf[msg.sender] = commitment;
        emit Committed(msg.sender, commitment);
    }

    // ---------------------------------------------------------------------------------------------
    // Reveal
    // ---------------------------------------------------------------------------------------------

    /// @notice Reveal the option and salt behind `msg.sender`'s commitment.
    /// @dev Only during `[commitEnd, revealEnd)`. Reverts on unknown voter, duplicate reveal, an
    ///      option outside `0..2`, or a hash that does not match the stored commitment. Because the
    ///      hash binds `msg.sender`, nobody can reveal on another voter's behalf.
    function reveal(uint8 option, bytes32 salt) external {
        if (block.timestamp < commitEnd || block.timestamp >= revealEnd) revert NotRevealPhase();

        bytes32 stored = commitmentOf[msg.sender];
        if (stored == bytes32(0)) revert NoCommitment();
        if (hasRevealed[msg.sender]) revert AlreadyRevealed();
        if (option >= OPTION_COUNT) revert InvalidOption();
        if (computeCommitment(msg.sender, option, salt) != stored) revert CommitmentMismatch();

        hasRevealed[msg.sender] = true;
        unchecked {
            // Bounded by the number of distinct addresses that committed; cannot overflow.
            _tally[option] += 1;
            totalRevealed += 1;
        }
        emit Revealed(msg.sender, option);
    }

    // ---------------------------------------------------------------------------------------------
    // Finalize
    // ---------------------------------------------------------------------------------------------

    /// @notice Settle the round. Anyone may call, exactly once, at or after `revealEnd`.
    /// @dev Ties select the lowest option number. Zero reveals produce `Outcome.NoResult`, which is
    ///      distinct from option 0 winning.
    function finalize() external {
        if (block.timestamp < revealEnd) revert RevealPhaseNotOver();
        if (outcome != Outcome.Pending) revert AlreadyFinalized();

        uint256 revealed = totalRevealed;
        if (revealed == 0) {
            outcome = Outcome.NoResult;
            emit Finalized(Outcome.NoResult, 0, 0);
            return;
        }

        uint8 best = 0;
        uint256 bestVotes = _tally[0];
        for (uint8 i = 1; i < OPTION_COUNT; ++i) {
            // Strict comparison: an equal count never displaces a lower option.
            if (_tally[i] > bestVotes) {
                best = i;
                bestVotes = _tally[i];
            }
        }

        outcome = Outcome.Decided;
        winningOption = best;
        emit Finalized(Outcome.Decided, best, revealed);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Hash a voter's choice the way `reveal` will check it.
    /// @dev Pure function of the inputs plus this contract's chain id and address.
    function computeCommitment(address voter, uint8 option, bytes32 salt) public view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(this), voter, option, salt));
    }

    /// @notice Revealed vote count for one option. Reverts for `option >= OPTION_COUNT`.
    function tally(uint8 option) external view returns (uint256) {
        if (option >= OPTION_COUNT) revert InvalidOption();
        return _tally[option];
    }

    /// @notice All three revealed vote counts.
    function tallies() external view returns (uint256[OPTION_COUNT] memory) {
        return _tally;
    }

    /// @notice True while commits are accepted.
    function isCommitPhase() external view returns (bool) {
        return block.timestamp < commitEnd;
    }

    /// @notice True while reveals are accepted.
    function isRevealPhase() external view returns (bool) {
        return block.timestamp >= commitEnd && block.timestamp < revealEnd;
    }

    /// @notice True once `finalize` may be called (whether or not it already has been).
    function isFinalizable() external view returns (bool) {
        return block.timestamp >= revealEnd;
    }
}
