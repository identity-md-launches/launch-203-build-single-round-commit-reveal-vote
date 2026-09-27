# CommitRevealVote

A single-round commit–reveal vote among the options `0`, `1` and `2`. One contract, no owner, no
tokens, no randomness, no admin functions. Everything the contract does is decided by two immutable
timestamps set in the constructor and by `block.timestamp`.

| Item | Value |
| --- | --- |
| Contract | `src/CommitRevealVote.sol` |
| Solidity | `0.8.24` (pinned in `foundry.toml`, `evm_version = "paris"`, optimizer 200 runs) |
| Deploy script | `script/Deploy.s.sol` |
| ABI | `docs/abi/CommitRevealVote.json` |
| Target network | Sepolia, chain id `11155111` (Anvil `31337` allowed for local runs; mainnet refused) |
| Dependencies | `lib/forge-std` (vendored as plain files, no submodule, no network needed) |

## Exact behaviour

### Timeline

Let `T` be `block.timestamp` at deployment, `commitEnd = T + commitDuration`,
`revealEnd = commitEnd + revealDuration`. Both durations must be non-zero.

| Phase | Condition | Allowed calls |
| --- | --- | --- |
| Commit | `block.timestamp < commitEnd` | `commit` |
| Reveal | `commitEnd <= block.timestamp < revealEnd` | `reveal` |
| Finalization | `block.timestamp >= revealEnd` | `finalize` (once) |

The boundaries are inclusive on the left and exclusive on the right. At exactly `commitEnd`,
`commit` reverts and `reveal` is accepted. At exactly `revealEnd`, `reveal` reverts and
`finalize` is accepted.

### Commitment format

```
commitment = keccak256(abi.encode(block.chainid, address(this), voter, uint8 option, bytes32 salt))
```

`computeCommitment(voter, option, salt)` returns this value on-chain. Because the chain id, the
contract address and the voter address are inside the hash, a commitment cannot be replayed on a
different chain, on a different instance of the contract, or by a different address. The salt must
be a secret random 32-byte value chosen by the voter; the option space is only three values, so an
unsalted or predictable-salt commitment is trivially brute-forced.

### `commit(bytes32 commitment)`

- Reverts `CommitPhaseOver` if `block.timestamp >= commitEnd`.
- Reverts `EmptyCommitment` if `commitment == 0` (zero is the "never committed" sentinel).
- Reverts `AlreadyCommitted` if the caller already has a commitment. Commitments cannot be replaced
  or withdrawn.
- Otherwise stores the commitment for `msg.sender` and emits `Committed(voter, commitment)`.

The contract cannot know the option at commit time. A voter who commits to an option outside
`0..2` has a valid commitment that can never be revealed.

### `reveal(uint8 option, bytes32 salt)`

Checks, in order:

1. `NotRevealPhase` unless `commitEnd <= block.timestamp < revealEnd`.
2. `NoCommitment` if `msg.sender` never committed.
3. `AlreadyRevealed` if `msg.sender` already revealed.
4. `InvalidOption` if `option >= 3`.
5. `CommitmentMismatch` if `computeCommitment(msg.sender, option, salt)` differs from the stored
   commitment (wrong salt, wrong option, or a commitment made for another address).

On success it marks the voter revealed, increments the tally for `option` and `totalRevealed`, and
emits `Revealed(voter, option)`. Only `msg.sender`'s own commitment is ever checked, so a third
party who learns a voter's option and salt cannot reveal on that voter's behalf.

### `finalize()`

- Reverts `RevealPhaseNotOver` if `block.timestamp < revealEnd`.
- Reverts `AlreadyFinalized` on any call after the first successful one.
- Anyone may call it. There is no privileged finalizer.
- If `totalRevealed == 0`, sets `outcome = NoResult` and emits `Finalized(NoResult, 0, 0)`.
  `NoResult` is distinct from option `0` winning.
- Otherwise selects the option with the highest revealed count; on a tie the lowest option number
  wins (the comparison is strict, so an equal count never displaces a lower option). Sets
  `outcome = Decided`, `winningOption`, and emits `Finalized(Decided, winner, totalRevealed)`.

Unrevealed commitments never count. Three commitments to option `2` and one reveal for option `1`
finalize with option `1` winning.

### State and views

| Function | Meaning |
| --- | --- |
| `commitEnd()`, `revealEnd()` | immutable schedule |
| `OPTION_COUNT()` | `3` |
| `commitmentOf(address)` | stored hash, `0` if none |
| `hasRevealed(address)` | reveal flag |
| `tally(uint8)` | revealed count for one option; reverts `InvalidOption` for `>= 3` |
| `tallies()` | all three counts |
| `totalRevealed()` | number of successful reveals |
| `outcome()` | `0 = Pending`, `1 = NoResult`, `2 = Decided` |
| `winningOption()` | meaningful only when `outcome == Decided` |
| `isCommitPhase()`, `isRevealPhase()`, `isFinalizable()` | phase helpers |

### Voter workflow

```
# 1. pick a secret salt (32 random bytes) and an option in 0..2
# 2. before commitEnd
cast call  $VOTE "computeCommitment(address,uint8,bytes32)(bytes32)" $ME 1 $SALT --rpc-url $RPC
cast send  $VOTE "commit(bytes32)" $COMMITMENT --rpc-url $RPC --account <keystore>
# 3. during [commitEnd, revealEnd)
cast send  $VOTE "reveal(uint8,bytes32)" 1 $SALT --rpc-url $RPC --account <keystore>
# 4. at or after revealEnd, anyone
cast send  $VOTE "finalize()" --rpc-url $RPC --account <keystore>
cast call  $VOTE "outcome()(uint8)" --rpc-url $RPC
cast call  $VOTE "winningOption()(uint8)" --rpc-url $RPC
```

## Reproduction (offline)

The toolchain on the verifier has Foundry and a cached `solc 0.8.24`. Nothing is downloaded.

```
forge build --offline
forge test --offline
forge fmt --check
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline
```

`forge test --offline` runs 50 tests: 42 in `test/CommitRevealVote.t.sol` (6 fuzz) and 8 in
`test/Deploy.t.sol` (2 fuzz). (`test/scratch/` adds one local-only opcode scan and is not part
of the delivered suite.) The suite covers: schedule construction; commitment binding of chain
id, contract address, voter, option and salt; one commitment per address; commit rejected exactly
at `commitEnd` and later; reveal accepted exactly at `commitEnd` and at `revealEnd - 1`, rejected
before `commitEnd` and exactly at `revealEnd`; wrong salt; wrong option; wrong caller (with and
without their own commitment); unknown voter; invalid option `>= 3`; duplicate reveal; finalize
rejected before `revealEnd` and accepted exactly at it; permissionless finalize; double finalize;
zero reveals giving `NoResult`; a single option-0 reveal giving `Decided`; majority; every tie
pattern; unrevealed commitments not counting; and a fuzz over all vote distributions of up to six
votes per option asserting the lowest-index argmax. No test calls `vm.setEnv`.

## Deployment

Deployment is **on**. The target is Sepolia (`11155111`). This repository holds no key, no
keystore and no RPC URL; the network's own deployer runs the script after review, and this
assignment cannot broadcast. The address, transaction hash and explorer link below are therefore
filled in by the deployer at launch.

### Demo parameters

| Constructor argument | Type | Value | Meaning |
| --- | --- | --- | --- |
| `commitDuration` | `uint256` | `172800` | 2 days of commits after deployment |
| `revealDuration` | `uint256` | `172800` | 2 days of reveals after `commitEnd` |

ABI-encoded constructor arguments:

```
0x000000000000000000000000000000000000000000000000000000000002a300000000000000000000000000000000000000000000000000000000000002a300
```

Durations rather than absolute timestamps were chosen so the same arguments are valid whenever the
deployment transaction is actually mined, including through a factory whose `msg.sender` is not a
person. The contract takes no owner argument and has nothing an owner could do.

### Deployment record

| Field | Value |
| --- | --- |
| Network | Sepolia (`11155111`) |
| Contract address | _to be filled by the network deployer_ |
| Deployment tx hash | _to be filled by the network deployer_ |
| Explorer | `https://sepolia.etherscan.io/address/<address>` |
| Constructor args | `(172800, 172800)` |
| Compiler | `solc 0.8.24`, optimizer on, 200 runs, `evm_version paris`, `bytecode_hash none` |

### Operator-only deploy command

```
EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy \
  --rpc-url <sepolia rpc> --account <keystore name> --broadcast
```

`run()` reads only `EXPECTED_CHAIN_ID`. A non-zero value must equal the connected chain id; `0`
skips that pin. On every path the chain must be `31337` or `11155111`, so a mainnet RPC is refused
before anything is broadcast. Exactly one contract is created between `vm.startBroadcast()` and
`vm.stopBroadcast()`.

### Test accounts

Local runs use Anvil's default funded accounts; nothing in this repository hard-codes an address.
The unit tests use labelled synthetic addresses (`alice`, `bob`, `carol`, `dave`, `anyone`) created
with `makeAddr`.

## Assumptions and non-goals

- **One address, one vote, no Sybil resistance.** Addresses are free. This contract measures the
  votes of addresses that chose to participate, nothing more. Do not use its outcome for anything
  that requires a bounded electorate.
- **No tokens.** There is no voting weight, no deposit and no reward. The task also forbids a launch
  token; none is included.
- **Timestamps.** Phases are gated by `block.timestamp`, which a block builder can nudge by a few
  seconds. A schedule of days makes that irrelevant; a schedule of seconds would not.
- **Reveal withholding.** A voter may commit and never reveal. The contract charges nothing for
  that and counts only reveals. Silence is not a vote and cannot be distinguished from a lost salt.
- **Commit-phase privacy is only as good as the salt.** With three options, an unsalted commitment
  is brute-forceable in three hashes.
- **No re-runs.** One round per deployment. A new vote is a new contract.
- **Immutable schedule.** Nobody can extend or shorten a phase after deployment.

## Incomplete checks

- The contract has not been deployed by this assignment; the Sepolia record above is empty until
  the network deployer fills it.
- The launch policy's project floor (constructor execution through the factory, runtime size,
  forbidden opcodes) is replicated in `test/scratch/` for local confidence only; the authoritative
  run is the verifier's.
- Tests are not an audit. See `REVIEW.md` for the independent review and the edges it lists.
