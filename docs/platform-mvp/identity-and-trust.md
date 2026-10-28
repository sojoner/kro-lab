# Identity and trust

Cross-cluster trust uses a split identity model: controllers authenticate to spokes with [projected service account tokens](https://kubernetes.io/docs/concepts/storage/projected-volumes/#serviceaccounttoken) whose issuer is the hub API server ([service account issuer discovery](https://kubernetes.io/docs/reference/access-authn-authz/service-accounts-admin/#service-account-issuer-discovery)); humans authenticate through [Dex](https://dexidp.io/docs/). Each spoke API server validates both issuers through an [`AuthenticationConfiguration`](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-authentication-configuration).

## Identities

| Identity Type | Issuer | Token Type | Rotation | Use Case |
|--------------|--------|-----------|----------|----------|
| **Service** (controllers) | Hub kube-apiserver | Projected service account token (audience-bound) | Kubelet (~1h) | Binding controllers → spoke API |
| **Human** (platform admins) | Dex IDP | OIDC id_token / access_token | Standard OIDC refresh | kubectl, platform admin operations |
| **Application** | Dex IDP | Signed JWT | n/a | oidc-verifier `/verify` endpoint |

## Architecture

```
HUB CLUSTER                              SPOKE CLUSTER (e.g. kind-eu-storage)
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
[Bucket Binding Controller Pod]           │
  │ SA: bucket-binding-controller         │
  │ Projected volumes:                    │   [ValidatingAdmissionPolicy]
  │   …/tokens/eu-storage-token           │     restrict-clusterrole-management
  │   audience: homelab:eu-storage-spoke  │     protect-system-namespaces
  │                                       │     protect-auth-config
  │ Kubelet auto-rotates token file       │
  │                                       │   [ClusterRole: hub-bucket-binding-controller]
[Dex IDP]                                 │     claims: read all ns, write tenant ns
  │ Human auth only                       │
  │ /dex/keys (JWKS)                      │   [Rook / KubeVirt operators]
  │ /dex/token (OAuth2)                   │     (unaffected)
  │                                       │
  │                                       │   [oidc-verifier]
  │                                       │     (unaffected — JWKS polling)
└───────────────────────────────────────  └───────────────────────────────────────
```

## Trust properties

| Property | Mechanism |
|----------|-----------|
| Spoke authentication | `AuthenticationConfiguration` with two JWT issuers: the hub (controllers) and Dex (humans) |
| Controller credential | Projected service account token read from a file (`BearerTokenFile`); the kubelet rotates it |
| Trust boundary | `claimValidationRules` accept only service accounts from the hub's `default` namespace |
| Identity mapping | `hub:system:serviceaccount:<namespace>:<name>` for controllers; `dex:<subject>` and `dex:<group>` for humans |
| Token audience | A logical name, `homelab:<spoke>-spoke`, independent of the spoke's network address |
| Controller authorization | Explicit `ClusterRole` plus per-tenant `Role`, scoped to the controller's own resource kind |
| Failure mode | A missing token file fails the request; the provider removes any client certificate from the REST config, so there is no silent fallback |
| Guardrails | `ValidatingAdmissionPolicy` resources ([Admission guardrails](admission-guardrails.md)), with a bypass only for cluster-admin identities |

## Service Identity Flow

1. A binding controller pod starts with a projected SA token volume per spoke it serves, audience `homelab:<spoke>-spoke` (a logical name, not a URL — it stays valid if the spoke's network address changes)
2. Kubelet writes the token to `/var/run/secrets/tokens/<spoke>-token`, rotating it before expiry
3. ClusterProfile provider creates a REST config with `BearerTokenFile` pointing to this file, and strips any TLS client cert/key from the base kubeconfig so the token is the *only* usable credential — a missing token file fails the request instead of silently falling back to a cert
4. client-go reads the current token from the file on each API call
5. The spoke kube-apiserver validates the token against the hub's OIDC discovery endpoint and JWKS
6. `claimValidationRules` ensure only ServiceAccounts from the hub's `default` namespace can authenticate
7. The resulting identity (`hub:system:serviceaccount:default:bucket-binding-controller`, or `…:vm-binding-controller`) is authorized by RBAC — see below

## Spoke RBAC for the controllers

Authentication proves *who* the controller is; it grants no permissions by itself. Each spoke chart template authorizes the resulting identity to the minimum its service needs:

| Identity | Template | Cluster-wide | In tenant namespaces only |
|----------|----------|--------------|---------------------------|
| `hub:system:serviceaccount:default:bucket-binding-controller` | `bucket-binding-controller-rbac.yaml` | get/list/watch `objectbucketclaims` | create/update/patch/delete claims; get `configmaps` |
| `hub:system:serviceaccount:default:vm-binding-controller` | `vm-binding-controller-rbac.yaml` | get/list/watch `virtualmachines` | create/update/patch/delete VMs; get/create/update/delete `secrets` |

The cluster-wide read exists because the controllers' informers are cluster-wide; every write is confined to tenant namespaces (`tenants:` plus `extraNamespaces`). The bucket controller cannot read Secrets, so it never sees S3 credentials. A compromised controller identity cannot touch anything else on the spoke, including its own RBAC. `*ControllerRBAC.hubIdentity` in `chart/spoke/values.yaml` is the single source of truth for the subject name and must match the `claimMappings.username` prefix in `authConfiguration`. Tests `22-vm-console-rbac` and `28-bucket-tenant-rbac` check both scopes.

## Human Identity Flow

1. Platform admin signs in through Dex (OAuth2 / OIDC)
2. Dex issues signed JWT
3. Presented to spoke kube-apiserver as Bearer token
4. Spoke validates against Dex JWKS
5. Identity mapped to `dex:<sub>` with `dex:<groups>`
6. RBAC (`ClusterRoleBindings`) authorizes actions

## Application Trust (oidc-verifier)

The oidc-verifier on the spoke provides application-layer JWT verification:
- Polls Dex JWKS every 5 minutes
- Validates Bearer tokens at `/verify` endpoint
- Emits structured AUDIT logs
- Uses Dex as its trust anchor

## Deploying

AuthenticationConfiguration is managed via Helm:

```bash
# chart/spoke/values-<spoke>.yaml (audience is required per spoke)
authConfiguration:
  enabled: true
  hubIssuer:
    enabled: true
    url: "https://hub-control-plane:6443"
    audience: "homelab:eu-storage-spoke"
    claimValidationRules:
      - expression: 'claims.sub.startsWith("system:serviceaccount:default:")'
        message: "Only ServiceAccounts from the default namespace on the hub may authenticate."
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

Each spoke's kind config (generated from `kind-spoke.yaml.tmpl` by `make render-kind-config-<spoke>`) mounts its auth file from `deploy/platform-mvp/kind/<spoke>-auth/` — resolved relative to the template, not a hardcoded path — via:
- `extraMounts` (kind node → container)
- `apiServer.extraVolumes` (kubeadm → kube-apiserver pod)
- `--authentication-config` flag

## Manual Debugging

`hack/platform-mvp/sa-token-helper.sh` wraps a projected SA token file as a kubectl `ExecCredential`, so an operator can run `kubectl --context kind-eu-storage` using the same token the controller uses, without ever handling a kubeconfig cert:

```yaml
users:
  - name: bucket-binding-controller-debug
    user:
      exec:
        command: hack/platform-mvp/sa-token-helper.sh
        args: ["/var/run/secrets/tokens/eu-storage-token"]
        apiVersion: client.authentication.k8s.io/v1beta1
```
