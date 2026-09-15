# Discarded L1 Origin Lets a Rollup Dispute-Game Admit and Dispute Proofs Against Different L1 Views

| | |
|---|---|
| **Vulnerability Class** | Missing Validation / Cross-Path Provenance Binding |
| **Severity** | High |
| **Status** | Unresolved — fix status not independently confirmed at time of writing |

## Summary

While auditing the proof-verification logic of a rollup's on-chain dispute-game contract, I found that the function admitting a new proposal anchors its proof to one L1 block, while every later function that verifies a proof about that same proposal anchors to a different, independently derived L1 block. Nothing in the contract ties the two together, so the property that they should agree is enforced entirely off-chain rather than by the contract itself.

## Vulnerability Details / Root Cause

The contract admits a new proposal by verifying a proof against an L1 origin supplied in the proposer's own initialization data:

```solidity
bytes32 l1OriginHash = bytes32(proof[1:33]);
uint256 l1OriginNumber = uint256(bytes32(proof[33:65]));
// Verify claimed L1 origin hash matches actual blockhash
_verifyL1Origin(l1OriginHash, l1OriginNumber);

_verifyProof(
    proof[65:],
    proofType,
    gameCreator(),
    l1OriginHash,
    startingOutputRoot.root.raw(),
    uint64(startingOutputRoot.l2SequenceNumber),
    rootClaim().raw(),
    uint64(l2SequenceNumber()),
    intermediateOutputRoots()
);
```

`_verifyL1Origin` only confirms that the supplied pair names a genuine historical L1 block within a fairly wide lookback window:

```solidity
function _verifyL1Origin(bytes32 l1OriginHash, uint256 l1OriginNumber) internal view {
    if (l1OriginNumber >= block.number) {
        revert L1OriginInFuture(l1OriginNumber, block.number);
    }
    // ... confirms l1OriginHash matches the real blockhash at l1OriginNumber ...
    if (actualHash != l1OriginHash) {
        revert L1OriginHashMismatch(l1OriginHash, actualHash);
    }
}
```

That's the only check. It never relates `l1OriginNumber` to the L2 range being proposed, and `l1OriginHash` / `l1OriginNumber` are function-local — nothing writes them to storage. Every function that later verifies a proof about the same proposal, whether corroborating or disputing it, instead builds its journal from a completely different value:

```solidity
function verifyProposalProof(bytes calldata proofBytes) external {
    // ...
    _verifyProof(
        proofBytes[1:],
        proofType,
        msg.sender,
        l1Head().raw(),
        startingOutputRoot.root.raw(),
        uint64(startingOutputRoot.l2SequenceNumber),
        rootClaim().raw(),
        uint64(l2SequenceNumber()),
        intermediateOutputRoots()
    );
}

function l1Head() public pure returns (Hash) {
    return Hash.wrap(_getArgBytes32(0x34));
}
```

`l1Head()` is a value the protocol itself fixed when the game was created — it has no relationship to the origin the admission path checked. The contract ends up with two candidate "true" L1 origins for one proposal, produced by two different code paths, with nothing on-chain connecting them. The admission-time origin also can't be recovered afterward to check: it isn't in storage, isn't emitted in any event, and isn't returned by any getter — it exists only in the calldata of the transaction that admitted the proposal.

## Impact

Two consequences follow, independent of whether either is actively triggered. First, how stale the admission-time origin may be relative to the L2 range it's admitting is bounded only by general chain history, not by anything specific to the proposal — nothing on-chain stops an origin that's technically valid but poorly aligned with the range it covers. Second, because that origin is never retained anywhere, there's no way to reconstruct after an incident which L1 view a resolved proposal's proof actually committed to. On the live proposal I examined, neither consequence was currently realized — the two candidate origins were measurably apart, but both still comfortably covered the proposal's actual range, and the corroboration/dispute paths saw effectively no production usage to expose the gap in practice.

## Recommendation

Bound how stale the admission-time origin is allowed to be against the proposal itself, not just against general chain history — tightening the window down to roughly match real proposal cadence closes most of the gap. Emitting the admitted origin as an event at admission time is a cheap way to make the choice auditable afterward, even without changing the verification logic itself.
