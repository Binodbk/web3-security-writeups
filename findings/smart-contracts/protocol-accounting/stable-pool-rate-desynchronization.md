# One-Directional Price Guard in a Stable-Pool Rate Refresh Lets a Legitimate Rate Decrease Get Ignored

| | |
|---|---|
| **Vulnerability Class** | Protocol-Accounting / Invariant Violation |
| **Severity** | High |
| **Status** | Unresolved — fix status not independently confirmed at time of writing |

## Summary

While auditing a stable-swap pool's rate-refresh logic, I found that the function keeping the pool's internal exchange rate in sync with a wrapped asset's canonical rate only ever allows that rate to move upward. When the canonical rate legitimately decreases — for example after a validator-slashing event reduces the collateral backing the wrapped asset — the pool's stored rate doesn't follow it down, and the pool keeps pricing the asset above its real value.

## Vulnerability Details / Root Cause

The pool refreshes its price for a wrapped asset by comparing a freshly computed rate against the rate currently on file, and only commits the update in one direction:

```rust
// Skip if the new price is less than or equal to old price
if new_price <= old_price {
    return Some(());
}
```

This is called on every swap, so in normal operation it looks harmless — prices mostly go up. The problem is what it does when the canonical rate legitimately drops. The wrapped asset's issuance module tracks two independent numbers: the collateral it holds, and the amount of wrapped tokens issued against that collateral. Their ratio is the canonical rate. A slashing event reduces the collateral without reducing issuance, so the canonical ratio drops immediately — but the pool only samples that ratio through the guard above, which silently discards every decrease. The pool keeps quoting the old, now-too-generous rate until some other mechanism forces a correction, which this guard rules out entirely for downward moves.

## Impact

Once the canonical rate has dropped and the pool hasn't followed, minting the wrapped asset at the new, lower canonical rate and immediately swapping it into the pool at the stale, higher rate extracts value from the pool's liquidity providers. No privileged access is needed — the slashing event that creates the gap is a normal part of protocol operation, not something the person extracting value has to cause. The amount extractable is bounded by the size of the rate gap and by the pool's own liquidity, since slippage limits how much can be taken in one pass, and the opportunity persists until the rate is eventually corrected or slippage closes the margin.

## Recommendation

Replace the one-directional guard with a symmetric one: allow the stored rate to move in either direction, but clamp any single adjustment to a fixed maximum delta so one anomalous reading still can't do much damage.

```rust
let price_diff = if new_price > old_price {
    new_price.checked_sub(old_price)?
} else if old_price > new_price {
    old_price.checked_sub(new_price)?
} else {
    return Some(());
};

let clamped_price = if price_diff > max_delta {
    if new_price > old_price {
        old_price.checked_add(max_delta)?
    } else {
        old_price.checked_sub(max_delta)?
    }
} else {
    new_price
};
```

This keeps the original intent — one wildly anomalous reading can't move the price far — while making sure genuine decreases actually reach the pool.
