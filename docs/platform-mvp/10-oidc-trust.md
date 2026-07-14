# Phase 10 — OIDC Cross-Cluster Trust (v2)

**Updated:** feat/oidc-trust-v2 | **Status:** Migrated to AuthenticationConfiguration + Projected SA Tokens

## Overview

Cross-cluster trust follows a split identity model:

| Identity Type | Issuer | Token Type | Rotation | Use Case |
|--------------|--------|-----------|----------|----------|
| **Service** (controllers) | Hub kube-apiserver | Projected SA token (audience-bound) | Kubelet (~1h) | Binding controller → spoke API |
| **Human** (platform admins) | Dex IDP | OIDC id_token / access_token | Standard OIDC refresh | kubectl, platform admin operations |
| **Application** | Dex IDP | Signed JWT | n/a | oidc-verifier `/verify` endpoint |

## Architecture (v2)

```
HUB CLUSTER                              SPOKE CLUSTER (kind-us)
──────────                               ──────────────────────
                                         
[Hub kube-apiserver]                     [spoke kube-apiserver]
  │ OIDC issuer                           │ AuthenticationConfiguration
  │ /.well-known/openid-configuration     │   jwt:
  │ /openid/v1/jwks                       │     - issuer: hub (controllers)
  │                                       │       claimValidationRules:
  │                                       │         SA ns restriction
  │                                       │       claimMappings:
  │                                       │         username: "hub:"+sub
  │                                       │     - issuer: dex (humans)
  │                                       │       claimMappings:
  │                                       │         username: "dex:"+sub
  │                                       │         groups: "dex:"+groups
  │                                       │
[Binding Controller Pod]                  │
  │ SA: binding-controller                │
  │ Projected volumes:                    │   [ValidatingAdmissionPolicy]
  │   /var/run/secrets/tokens/us-token    │     restrict-clusterrole-management
  │     audience: <spoke-api-url>         │     protect-system-namespaces
  │     audience: <spoke-api-url>         │     protect-auth-config
  │                                       │
  │ Kubelet auto-rotates token file       │
  │                                       │
[Dex IDP]                                 │
  │ Human auth only                       │   [Widget Operator]
  │ /dex/keys (JWKS)                      │     (unaffected)
  │ /dex/token (OAuth2)                   │
  │                                       │   [oidc-verifier]
  │                                       │     (unaffected — JWKS polling)
└───────────────────────────────────────  └───────────────────────────────────────
```

## Key Changes from v1

| Component | v1 (legacy) | v2 |
|-----------|------------|-----|
| Spoke auth config | `oidc-*` CLI flags on kube-apiserver | `AuthenticationConfiguration` resource |
| Controller auth | Dex password grant → token-rotator → kubeconfig Secret | Projected SA token → BearerTokenFile in REST config |
| Token rotation | token-rotator (every 5min, SHA256 detection) | Kubelet (configurable, ~1h, file-based) |
| Trust boundaries | Any valid Dex token accepted | `claimValidationRules` restrict by namespace |
| Identity mapping | `oidc:<sub>` | `hub:system:serviceaccount:ns:sa` / `dex:<sub>` |
| Guardrails | None | `ValidatingAdmissionPolicy` (3 policies) |

## Service Identity Flow

1. Binding controller pod starts with projected SA token volume
2. Token is audience-bound to the spoke API server URL
3. Kubelet writes token to `/var/run/secrets/tokens/us-token`
4. ClusterProfile provider creates REST config with `BearerTokenFile` pointing to this file
5. client-go reads the current token from the file on each API call
6. Spoke kube-apiserver validates the token against hub's OIDC discovery endpoint
7. `claimValidationRules` ensure only the binding-controller SA can authenticate

## Human Identity Flow

1. Platform admin uses `dex-auth-plugin` (exec credential) or OAuth2 flow
2. Dex issues signed JWT
3. Presented to spoke kube-apiserver as Bearer token
4. Spoke validates against Dex JWKS
5. Identity mapped to `dex:<sub>` with `dex:<groups>`
6. RBAC (`ClusterRoleBindings`) authorizes actions

## Application Trust (oidc-verifier)

The oidc-verifier on the spoke continues to provide application-layer JWT verification:
- Polls Dex JWKS every 5 minutes
- Validates Bearer tokens at `/verify` endpoint
- Emits structured AUDIT logs
- Unaffected by the v2 changes (still uses Dex as its trust anchor)

## Deploying

AuthenticationConfiguration is managed via Helm:

```bash
# us/values.yaml
authConfiguration:
  enabled: true
  hubIssuer:
    enabled: true
    url: "https://hub-control-plane:6443"
    audience: "https://us-control-plane:6443"
    claimValidationRules:
      - expression: 'claims.sub.startsWith("system:serviceaccount:default:")'
        message: "Only ServiceAccounts from the default namespace may authenticate."
    claimMappings:
      username:
        claim: sub
        prefix: "hub:"
  dexIssuer:
    enabled: true
    url: "https://dex.example.com/dex"
    audiences:
      - kubernetes
    claimMappings:
      username:
        claim: sub
        prefix: "dex:"
      groups:
        claim: groups
        prefix: "dex:"
```

The `kind-us.yaml` cluster config mounts the auth file from `/tmp/kro-us-auth/` via:
- `extraMounts` (kind node → container)
- `apiServer.extraVolumes` (kubeadm → kube-apiserver pod)
- `--authentication-config` flag

## Deprecated Components

- **token-rotator** — replaced by Kubelet-managed projected token rotation
- **`oidc-*` CLI flags** — replaced by AuthenticationConfiguration
- **`{region}-access-kubeconfig` Secrets** — no longer written by token-rotator