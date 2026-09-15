# Unsynchronized Shared Opcode Table Lets an Unauthenticated RPC Call Corrupt What a Node's Consensus Path Executes

| | |
|---|---|
| **Vulnerability Class** | Race Condition (TOCTOU) on Shared Mutable State → Consensus Divergence / DoS |
| **Severity** | Critical |
| **Status** | Fixed — the vendor shipped a release that isolates the read-only path's table from the consensus path, independently confirmed against the public source history |

## Summary

While auditing a blockchain node's virtual machine, I found that its opcode dispatch table is a single, process-wide, mutable object rebuilt on every lookup — and that unauthenticated, read-only RPC calls reach that same lookup on unlocked worker threads, with no relationship to the lock that serializes the node's own consensus execution. Racing the two let an RPC caller make the consensus thread briefly observe the wrong handler for an opcode, which was enough to permanently desynchronize the node from the canonical chain.

## Vulnerability Details / Root Cause

Every place in the VM that needs "the current opcode table" called the same function, which fetched a shared table object and rewrote several of its entries in place before handing it back:

```java
public static JumpTable getTable() {
    JumpTable table = tableMap.get(LATEST_VERSION);

    if (VMConfig.allowEnergyAdjustment()) {
        adjustForFairEnergy(table);      // installs one variant of an opcode
    }
    if (VMConfig.allowSelfdestructRestriction()) {
        adjustSelfdestruct(table);       // installs a different variant of the same opcode
    }
    return table;
}
```

The table itself was a plain, unsynchronized array, and every opcode dispatch re-read it fresh:

```java
private final Operation[] table = new Operation[256];

public Operation get(int op) { return table[op]; }
public void set(Operation op) { table[op.getOpcode()] = op; }

// dispatch loop
Operation op = jumpTable.get(currentOpcode);
```

Consensus-path execution — processing blocks and transactions as part of the chain — is fully serialized by a single lock elsewhere in the codebase. The RPC path serving read-only "constant calls" is not; it's designed to run concurrently, since it's just meant to answer queries like token balances. Both paths called the same `getTable()`, on the same shared array. Two of that table's entries for one particular opcode had materially different effects on persistent state — one deleted an account outright, the other only transferred its balance and conditionally kept the account — so whichever variant a given execution happened to observe at the instant it read that slot depended on what the unlocked RPC thread was doing to the shared array at that moment, not on anything about the transaction itself.

## Impact

A consensus-path execution that observed the wrong variant computed a different result than every other node processing the same block — in the case I examined, deleting a contract that canonical execution retained. Block validation on the affected node compared only the transaction's outcome code, not a full state root, so nothing caught the divergence when it happened; it was written to disk on the very next checkpoint. The failure only became visible later, when a subsequent block referenced the now-locally-missing contract: the node couldn't validate that block, rejected its peer, and a restart on the same database didn't recover it, since the missing contract was still missing. Because the read-only RPC surface this depends on is a normal, recommended production configuration — needed to serve ordinary balance queries — the precondition existed on typical nodes, not just unusually configured ones.

## Recommendation

Give the read-only path its own table instance entirely, isolated from the one consensus execution reads, so no code path outside serialized consensus execution can affect what consensus sees. I independently verified this is the direction the vendor's shipped fix takes: the read-only path now resolves against a dedicated table built once, separate from the table the consensus path uses, which removes the shared mutable state the race depended on.
