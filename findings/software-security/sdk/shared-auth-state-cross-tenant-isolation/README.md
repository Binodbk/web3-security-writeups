# Cross-Tenant Confused Deputy via Shared Module-Level Authentication State in a Wallet SDK

## Overview

A TypeScript SDK for a hosted wallet/signing service stored authentication
credentials and transport configuration in module-level (process-wide)
mutable state rather than per-client-instance state. Constructing a second
authenticated client silently redirected every previously constructed
client's subsequent operations to the new client's credentials.

## Target / Component

An open-source TypeScript SDK for a hosted wallet-as-a-service platform,
specifically its API-client / transport layer.

## Vulnerability Class

Shared/global mutable state → cross-tenant confused deputy (authorization and
signing-context isolation failure).

## Severity

Reported as Critical severity by the submitter; not independently re-scored
here.

## Root Cause

The SDK's public client type is designed to look like a self-contained
credential domain — each instance is constructed with its own API key and
wallet secret, the natural pattern for an application serving multiple
tenants with per-tenant credentials. Internally, however, the SDK's HTTP
transport and its authentication interceptor were held in module-level
variables shared by the whole process, and every client construction
overwrote them. Objects the SDK returns (such as account handles) captured a
reference to this shared transport rather than to any credential set fixed at
their own creation time, resolving "whose credentials do I sign with" at call
time, not at construction time.

## Technical Analysis

```text
module state:
    transport = null

Client.construct(credentials):
    transport = build_transport(credentials)   // overwrites, not per-instance
    return Client(transport)                   // handle just references module state

handle.send(...):
    return transport.sign_and_send(...)        // resolves "transport" NOW, not at construction
```

An application serving several tenants naturally constructs and caches one
SDK client per tenant, since the public API offers no per-call credential
override. Because the transport is shared rather than per-instance, whichever
client was constructed *most recently* determines which credentials every
previously constructed client's *subsequent* calls actually use. This makes
the failure deterministic rather than a narrow timing race: reversing the
order two clients are constructed reliably reverses which tenant's operations
get misattributed, and the same misattribution was observed reliably under
ordinary concurrent load with no special timing control needed.

## Security Invariant

Two SDK client instances constructed with different credentials should be
fully isolated credential domains — an operation issued through a handle
derived from client A should always execute with client A's authority,
regardless of what else has been constructed in the same process.

## Impact

In a backend that keeps one SDK client cached per tenant — the pattern the
public API design encourages — a request correctly authenticated as one
tenant can, depending purely on construction order elsewhere in the process,
be signed and executed using a *different* tenant's wallet credentials. This
is a direct authorization failure: the caller never needs to possess or
supply the other tenant's secrets. Other language implementations of the same
SDK family isolate credentials per instance, indicating this is an
implementation defect specific to this SDK rather than an inherent limitation
of the underlying platform.

## Conceptual Attack Scenario

A multi-tenant backend constructs and caches an SDK client per tenant, as the
API design encourages. Once more than one such client exists in the same
process, a request authenticated only as one tenant can be served using
whichever tenant's client was constructed most recently — including signing
and broadcasting a transaction from that other tenant's wallet — without the
caller ever presenting that tenant's credentials.

## Remediation

Make the transport and its credentials a property of each client instance
rather than of the module, and thread that per-instance transport through
every object the client returns, so an operation's authority is fixed at the
moment its handle was created rather than resolved from shared state at call
time.

## Research Notes

SDKs that present a per-instance construction API implicitly promise
per-instance isolation; that promise has to hold all the way down the call
stack, not just at the constructor. A shared singleton hiding behind a
per-instance-looking public interface is a durable pattern worth checking for
in any client library, not just this one.
