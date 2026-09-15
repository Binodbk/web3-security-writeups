# Shared Module-Level Auth State in a Wallet SDK Lets One Client's Requests Get Signed With Another Client's Credentials

| | |
|---|---|
| **Vulnerability Class** | Shared Mutable State / Cross-Tenant Confused Deputy |
| **Severity** | Critical |
| **Status** | Unresolved — fix status not independently confirmed at time of writing |

## Summary

While auditing a TypeScript SDK for a hosted wallet-signing service, I found that its authentication and transport state live in mutable, module-level variables shared by every client instance in the process, rather than being scoped to each client. Constructing a second client silently overwrites the credentials and transport that operations issued through the first client will use going forward.

## Vulnerability Details / Root Cause

The SDK's transport and its auth configuration are held at module scope:

```ts
let axiosInstance: AxiosInstance;
export let config: ClientOptions | undefined = undefined;
```

Every client construction reassigns them:

```ts
export const configure = (options: ClientOptions) => {
  config = { ...options };

  axiosInstance = Axios.create({ baseURL: options.basePath });

  axiosInstance = withAuth(axiosInstance, {
    apiKeyId: options.apiKeyId,
    apiKeySecret: options.apiKeySecret,
    walletSecret: options.walletSecret,
  });
};
```

and every generated API call resolves the transport at request time, not at the caller's construction time:

```ts
export const apiClient = async (requestConfig) => {
  const response = await axiosInstance(requestConfig);
  return response;
};
```

The public client type looks like a self-contained credential domain — you construct it with its own API key and wallet secret, exactly the pattern a multi-tenant application needs. But because the transport is shared module state rather than an instance property, whichever client was constructed *most recently* determines which credentials every previously constructed client's *subsequent* calls actually use. Objects the SDK hands back — account handles, for instance — capture a reference to this shared transport rather than to any credential set fixed at their own creation, so "whose credentials do I sign with" is resolved at call time, not at construction time.

## Impact

In a backend that keeps one client cached per tenant — the pattern the public API design encourages, since there's no way to pass credentials on a per-call basis — a request correctly authenticated as one tenant can be signed and executed using a *different* tenant's wallet credentials, purely depending on construction order elsewhere in the process. The caller doesn't need to possess or supply the other tenant's secrets at all. This isn't a narrow timing race: reversing the order two clients are constructed reliably reverses which tenant's operations get misattributed, and the same misattribution shows up reliably under ordinary concurrent load with no special timing control needed.

## Recommendation

Make the transport and its credentials a property of each client instance instead of the module, and thread that per-instance transport through every object the client returns, so an operation's authority is fixed at the moment its handle was created rather than resolved from shared state at call time.
