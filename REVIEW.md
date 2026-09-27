# Review: CommitRevealVote

Scope: `src/CommitRevealVote.sol`, `script/Deploy.s.sol`, `test/*.t.sol`, `foundry.toml`.
Method: read the contract as an attacker along the checklist below, then wrote or confirmed a test
for each concrete concern. What was re-run is listed at the end.

## Findings

| # | Severity | Finding | Disposition |
| --- | --- | --- | --- |
| 1 | Info | Commit can lock in an option outside `0..2`; the voter can never reveal. | Accepted. The contract cannot see the option at commit time. Documented; `test_revealRejectsInvalidOption` covers the reveal-side rejection. |
| 2 | Info | Reveal withholding is free: a voter can commit and stay silent, and silence changes the tally. | Accepted by design (task forbids deposits and tokens). Documented in README. `test_unrevealedCommitmentsDoNotCount` fixes the behaviour. |
| 3 | Info | Three-option space means commit privacy depends entirely on the salt. | Documented. Nothing on-chain can enforce salt quality. |
| 4 | Info | `block.timestamp` gates every phase. | Accepted; phases are days long in the demo. Boundary tests pin the exact semantics at `commitEnd` and `revealEnd`. |
| 5 | Low | Original deploy script rejected `EXPECTED_CHAIN_ID=0`, which is the network's standard offline dry run. | Fixed: `0` skips the pin; the allow-list (`31337`, `11155111`) still applies on every path. `test_zeroExpectedChainIdSkipsPinButKeepsAllowList` and `testFuzz_refusesAnyDisallowedChain` cover both halves. |

No findings of Medium or higher severity.

## Checklist

**Who can call what.** No owner, no roles, no initialiser, no fallback or receive. `commit`,
`reveal` and `finalize` are open to everyone by design; each is gated only by time and by the
caller's own state. Reveal checks `msg.sender`'s commitment only, so no path exists to reveal for
another address (`test_revealRejectsWrongCaller`, `testFuzz_revealByOtherCallerFails`).

**Value in and out.** The contract holds no ETH and no tokens, has no payable function, and makes
no external calls. Reentrancy is not reachable.

**Arithmetic.** Two `unchecked` increments, both bounded by the number of distinct addresses that
committed (each address reveals at most once). No division, no casts narrower than the input, no
loops over user-controlled arrays. The finalize loop is three iterations.

**Time and ordering.** Boundaries are `[commitEnd, revealEnd)` with `>=` / `<` throughout;
`testFuzz_phaseGates` checks all three functions across arbitrary timestamps. Front-running a
commit reveals nothing useful (the hash hides the option). Front-running a reveal is pointless
(it is bound to the revealer). Front-running `finalize` produces the same result whoever sends it.

**Signatures and identity.** No signatures. The commitment hash includes chain id, contract
address and voter, which is the replay protection this scheme needs; there is no nonce because
each address commits exactly once (`test_commitRejectsSecondCommitmentFromSameAddress`).

**External dependencies.** None. No oracles, no delegatecall, no proxies, no inherited code beyond
the compiler's own. The runtime was scanned for `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`
(stepping over PUSH immediates) in a scratch test and none were found.

**Launch-floor constraints.** Constructor is nonpayable, takes two `uint256`, no dynamic arguments,
no `msg.sender` use, no owner. Runtime is well under the EIP-170 limit.

## What the tests do not cover

- Behaviour under an actual Sepolia deployment (gas, explorer verification). The verifier's dry run
  is against a local EVM.
- Voters that are contracts. Nothing in the design distinguishes them, and nothing should.
- Any social-layer property: bounded electorates, honest reveal rates, salt hygiene.

## Re-run for this review

```
forge build --offline          # Compiler run successful, solc 0.8.24
forge test --offline           # 50 passed, 0 failed, 0 skipped
forge fmt --check              # clean
EXPECTED_CHAIN_ID=0 forge script script/Deploy.s.sol:Deploy --offline        # ok, one contract
EXPECTED_CHAIN_ID=11155111 forge script script/Deploy.s.sol:Deploy --offline # refused: UnexpectedChainId(11155111, 31337)
```

Tests passing do not constitute a security audit. This review was written by the same contributor
who wrote the contract; an independent adversarial review is still the right next step if the
outcome of a vote is ever used to move funds or permissions.
