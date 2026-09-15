# Web3 Security Research

A public portfolio of security research across smart contracts and blockchain
infrastructure.

## Scope

- **Smart contracts** — access control and protocol-accounting / invariant analysis
- **Blockchain infrastructure** — fault-proof and rollup verification systems, consensus-layer correctness
- **Software security** — SDK and client-library trust-boundary and authorization analysis

## What this repository contains

Each writeup focuses on root cause, the security invariant involved, realistic
impact, and the defensive lesson it demonstrates. Writeups are reconstructed
from first principles rather than copied from original submission material.

## What this repository intentionally excludes

Exploit code, proof-of-concept scripts, executable reproduction steps, and
other operational detail that could materially lower the effort required to
exploit a live system are not included here. Where a finding's disclosure
status isn't established, it isn't published at all.

## Organization

Findings are grouped by research domain rather than by severity:

```text
findings/
├── smart-contracts/
│   ├── access-control/
│   └── protocol-accounting/
├── blockchain-infrastructure/
│   ├── fault-proofs/
│   └── consensus/
└── software-security/
    └── sdk/
```
