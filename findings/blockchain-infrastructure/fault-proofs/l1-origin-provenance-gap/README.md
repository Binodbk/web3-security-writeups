# L1-Origin Provenance Gap in a Rollup Dispute-Game Verifier

## Overview

In a multi-proof dispute-game (fault-proof) system for an L2 rollup, the
on-chain verifier admits a new state proposal using a proof anchored to one L1
block, then later verifies corroborating or disputing proofs about that same
proposal using a second, independently derived L1 block. Nothing in the
contract ties the two together, so the property that they should agree is
enforced only by off-chain policy, not by the contract itself.

## Target / Component

An Ethereum L2's on-chain dispute-game / fault-proof verifier — the contract
responsible for admitting L2 state proposals and adjudicating disputes about
them via multiple independent proving systems.

## Vulnerability Class

Missing validation / cross-path state-provenance binding gap.

## Severity

The reviewing platform recorded this as High severity (High likelihood ×
High impact) in its own triage. Independent technical analysis at the time of
writing concluded real-world impact was low, since the one live proposal
examined had both candidate L1 origins covering the same L2 range with
comfortable margin. Both assessments are recorded here rather than reconciled;
only the platform's own final resolution can authoritatively settle which
stands.

## Root Cause

The verifier admits a proposal by checking a proof whose validity is anchored
to an L1 block (an "L1 origin") supplied as part of the proposer's
initialization data. The only on-chain check applied to that origin confirms
it names a genuine historical L1 block within a bounded lookback window — it
is never checked against the L2 range being proposed, and it is never written
to contract storage. Every subsequent function that verifies a proof about the
same proposal (a corroborating proof, a challenge, or a nullification)
instead derives its own L1 origin independently, from a value the protocol
fixed at game creation. The contract ends up with two candidate "true"
origins for one proposal, produced by two different code paths, with nothing
connecting them.

## Technical Analysis

The admission path treats the origin as transient input: validate its
authenticity, use it once to build a verification journal, then discard it.
Because it lives in a local variable rather than storage, no later call can
read it back for comparison. The dispute and corroboration paths don't need
to read it either, because they compute their own origin from an immutable
value fixed when the game was created. The design implicitly assumes the two
values stay close enough in practice to be interchangeable — an assumption
enforced entirely by whichever off-chain process selects the admission-time
origin, never by the contract.

```text
admit(proposal, origin_A):
    require(origin_A is a real, recent L1 block)   // authenticity only
    verify(proof, anchored_to = origin_A)
    // origin_A is now discarded — never stored

dispute(proposal):
    origin_B = protocol_fixed_origin_at_creation()  // independent of origin_A
    verify(proof, anchored_to = origin_B)
```

## Security Invariant

The L1 view used to admit a proposal and the L1 view used to adjudicate
disputes about that same proposal should be provably related — at minimum,
the dispute-time view should be guaranteed to be at least as current as, and
cover the same underlying data as, the admission-time view. The contract
should never be in a position where it cannot establish this relationship
after the fact.

## Impact

Two consequences follow from the missing binding, independent of whether the
gap is ever actively triggered: the staleness of the admission-time origin
relative to the proposed range is bounded only by a wide off-chain policy
window rather than by contract logic, and — because the admitted origin is
never persisted — there is no way to reconstruct after an incident which L1
view a resolved proposal's proof actually committed to. In the case
independently reviewed, neither consequence was currently realized: the
dispute/corroboration paths saw effectively no production usage, and the one
admitted proposal examined had a comfortable margin against both candidate
origins.

## Conceptual Attack Scenario

No specific attacker action is required to expose the gap — it exists on
every admitted proposal, because the admission path never records or bounds
the origin against the range it is proving. The realistic risk scenario is
one where the off-chain process selecting the admission-time origin behaves
incorrectly: because the contract never independently verifies the
relationship between that origin and the proposed range, a resulting mismatch
would not be caught on-chain, and — since the origin isn't retained anywhere
in contract state, events, or getters — could not be reconstructed after the
fact either.

## Remediation

Two complementary changes close the gap: bound the maximum age of the
admission-time origin against the proposal's own data range rather than only
against general chain history, tightening the current wide off-chain window
into an on-chain check; and emit the admitted origin at proposal creation, so
the choice becomes auditable after the fact even without changing the
verification logic itself.

## Research Notes

Validating that an input is *authentic* (a real, recent block) is not the
same as validating that it is *the right* input relative to what it's being
used to prove. Two verification paths can each look correct in isolation
while silently relying on an assumption that only holds off-chain. The lesson
generalizes to any system where two independent verification paths are
expected to agree on a piece of provenance data but nothing enforces that
agreement on-chain.
