# One-Directional Price Ratchet in a Stable-Pool Rate Oracle

## Overview

A stable-swap pool's internal record of a wrapped asset's exchange rate was
only ever allowed to move upward. When the canonical rate the pool tracks
decreased through a normal, expected external event, the pool's stored rate
did not follow it down, leaving the pool pricing the asset above its true
value.

## Target / Component

A parachain-based stable-asset AMM pool and its associated liquid-staking /
wrapped-token issuance module.

## Vulnerability Class

Protocol-accounting invariant violation — asymmetric (one-directional) state
synchronization.

## Severity

Reported as High severity by the submitter; not independently re-scored here
pending confirmation of the platform's final triage outcome.

## Root Cause

The pool refreshes its internal price for a wrapped asset by comparing a
freshly computed rate against its currently stored rate, committing the
update only when the new rate is higher. This guard likely intended to stop a
stale or manipulated low reading from ever writing down a legitimate rate —
but it also blocks every *legitimate* downward correction, including the
ordinary case where the wrapped asset's backing decreases through normal
protocol operation (for example, a validator-slashing event that reduces
underlying collateral without reducing the amount of wrapped tokens issued
against it).

## Technical Analysis

The issuance module tracks two independent quantities: the amount of
underlying collateral it holds, and the amount of wrapped tokens issued
against that collateral. Their ratio is the canonical exchange rate. An event
that reduces backing collateral without reducing issuance lowers that
canonical ratio immediately. The stable pool, however, only samples and
commits this ratio on its own schedule, gated by the one-directional guard —
so once the canonical rate drops, the pool keeps pricing swaps at its last
(now stale and too generous) committed rate until some other mechanism forces
a correction, which the guard prevents entirely for downward moves.

```text
fn refresh_rate(new_rate, stored_rate):
    if new_rate <= stored_rate:
        return   // silently skips every legitimate decrease
    stored_rate = new_rate
```

## Security Invariant

A pool's internal price for an asset should never remain more favorable to a
counterparty than the asset's true canonical backing for longer than a
bounded, symmetric adjustment window — the pool must track *decreases* in
backing at least as reliably as it tracks increases.

## Impact

While the canonical rate is desynchronized, minting the wrapped asset at the
new (lower) canonical rate and trading it into the stable pool at the stale
(higher) pool rate extracts value from the pool's other liquidity providers.
The magnitude is bounded by the size of the desynchronization and by the
pool's available liquidity, since slippage limits extraction per pass; the
opportunity persists until the pool rate is eventually corrected or slippage
erodes the margin.

## Conceptual Attack Scenario

Following a legitimate, externally triggered reduction in an asset's backing
collateral, a participant mints the wrapped asset at the new, lower canonical
rate and immediately exchanges it in the affected pool, which is still
quoting the older, higher rate. The round trip is profitable purely from the
rate gap; no privileged access or protocol manipulation is required, since
the desynchronizing event itself is a normal part of protocol operation, not
something the participant causes.

## Remediation

Replace the one-directional guard with a symmetric bound: allow the stored
rate to move in either direction, but clamp any single adjustment to a fixed
maximum delta. This preserves the original intent — protecting against one
wildly anomalous reading — while ensuring genuine decreases eventually
propagate into pool pricing.

## Research Notes

This is a useful example of a guard that solves the threat model it was
written for (a spurious downward spike) while silently reintroducing risk in
the threat model it wasn't written for (a legitimate downward correction).
Any invariant framed as "only move in this direction" is worth re-examining
for the case where the real world legitimately needs to move the other way.
