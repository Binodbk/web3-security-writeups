# 📂 Title: Cross-Chain Accounting Underflow Causes Permanent OVA Loss

| Metadata | Value |
| :--- | :--- |
| **Target/Project** | Overlayer |
| **Vulnerability Class** | Cross-Chain Accounting / Logic Error |
| **Severity** | 🔴 Critical |
| **Date Found** | 2026-3-28 |
| **Status** | ✅ Fixed |
| **Bounty/Reward** | Private |

---

## 📝 Summary

While reviewing Overlayer's LayerZero OFT integration, I identified a critical accounting flaw in the bridge accounting logic.

The protocol tracks in-flight OVA using a variable called `totalBridgedOut`. The counter is incremented on the hub chain during `_debit()` and decremented on the destination chain during `_credit()`. Because each deployment maintains independent storage, satellite chains attempt to decrement a value that was never incremented, causing an arithmetic underflow and reverting every inbound bridge transfer.

As a result, OVA is burned on the source chain but never minted on the destination chain, permanently destroying user funds.

---

## 🎯 Impact

An attacker is not required.

Every legitimate hub-to-satellite bridge transfer triggers the vulnerability.

Impact includes:

- Permanent destruction of bridged OVA
- Failed hub-to-satellite transfers
- Infinite LayerZero retry loops
- Complete loss of bridged user funds
- Cross-chain bridge functionality rendered unusable

Because the failure is deterministic, every affected transfer results in loss of funds.

---

## 🔍 Vulnerability Analysis & Discovery

While reviewing the protocol's cross-chain accounting model, I focused on how OVA tracks assets moving between chains.

The protocol maintains a variable called:

```solidity
uint256 public totalBridgedOut;
```

The intended purpose is to track OVA currently in transit.

### The Flawed Logic

When a user initiates a bridge transfer:

```solidity
function _debit(
    address from_,
    uint256 amountLD_,
    uint256 minAmountLD_,
    uint32 dstEid_
)
    internal
    override
    returns (uint256 amountSentLD, uint256 amountReceivedLD)
{
    (amountSentLD, amountReceivedLD) = super._debit(
        from_,
        amountLD_,
        minAmountLD_,
        dstEid_
    );

    totalBridgedOut += amountSentLD;
}
```

The hub burns the user's OVA and increments `totalBridgedOut`.

When the LayerZero message arrives on the destination chain:

```solidity
function _credit(
    address to_,
    uint256 amountLD_,
    uint32 srcEid_
)
    internal
    override
    returns (uint256 amountReceivedLD)
{
    amountReceivedLD = super._credit(
        to_,
        amountLD_,
        srcEid_
    );

    totalBridgedOut -= amountReceivedLD;
}
```

The destination chain attempts to decrement the same variable.

The issue is that these operations execute on different contract deployments.

```text
Hub Storage
------------
totalBridgedOut += amount

Satellite Storage
-----------------
totalBridgedOut -= amount
```

The hub increment never affects the satellite's storage.

On a fresh satellite deployment:

```text
totalBridgedOut = 0
```

The first inbound bridge transfer therefore executes:

```text
0 - amountReceivedLD
```

which immediately triggers a Solidity 0.8 arithmetic underflow.

The entire transaction reverts.

---

## 🚀 Proof of Concept (PoC)

### Attack Flow

1. User bridges OVA from the hub.
2. `_debit()` burns user tokens.
3. Hub increments `totalBridgedOut`.
4. LayerZero delivers the message.
5. Satellite executes `_credit()`.
6. Satellite performs:

```text
0 - amountReceivedLD
```

7. Arithmetic underflow occurs.
8. Transaction reverts.
9. Mint operation is rolled back.
10. User receives no OVA.

### Result

```text
Hub:
User OVA burned

Satellite:
User OVA never minted

Outcome:
Permanent loss of funds
```

### Validation

A Foundry PoC was created demonstrating:

- Initial bridge failure
- Infinite retry failures
- Complete storage isolation between deployments

Test results:

```text
Ran 3 tests

[PASS] test_CRIT01_hubStateDoesNotHealSatellite()
[PASS] test_CRIT01_retriesNeverRecover()
[PASS] test_CRIT01_satelliteCreditAlwaysUnderflows()

3 passed, 0 failed
```

---

## 🛠️ Remediation & Fix

The accounting variable should only be modified on the hub chain.

Example fix:

```solidity
if (block.chainid == hubChainId) {
    totalBridgedOut += amountSentLD;
}
```

and

```solidity
if (block.chainid == hubChainId) {
    totalBridgedOut =
        totalBridgedOut >= amountReceivedLD
        ? totalBridgedOut - amountReceivedLD
        : 0;
}
```

This ensures satellite deployments never attempt to update accounting state that belongs exclusively to the hub.

---


## 💡 Takeaway

Cross-chain deployments do not share state.

Whenever protocol accounting depends on values maintained across multiple chains, developers must explicitly synchronize those values or ensure all accounting updates occur on the same deployment.

Treating local storage as global state can result in catastrophic accounting failures and permanent fund loss.
