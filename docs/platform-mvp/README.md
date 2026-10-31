# Documentation

A hub-and-spoke platform on four kind clusters: tenants declare intents on the hub, the platform runs them on spokes. Each document shows its part with a diagram and the real code, and ends with the tests that prove it. Only what `make deploy` installs and `make validate` tests is described; `make check-docs` keeps links, diagrams and length honest.

| Document | Covers |
|----------|--------|
| [Use cases](use-cases.md) | The demo: eight acts, each proved by a test, and how to reach every UI |
| [Architecture](architecture.md) | Intents, Kro graphs, placement controllers, the fleet |
| [Identity and access](identity-and-access.md) | Tokens, Dex, kubectl login, workload identity, tenants, roles, admission |
| [Virtual machines](virtual-machines.md) | `VmSetIntent` on KubeVirt, ssh |
| [Object storage](object-storage.md) | `BucketIntent` on Rook and Ceph RGW, S3 with curl |
| [Management plane](management-plane.md) | The portal, measurement, metrics, logs, dashboards |
| [Operations](operations.md) | Clusters, deploy order, GitOps, adding a region |
| [Testing](testing.md) | The 34 end-to-end tests |
| [Decisions and limits](decisions.md) | Why it is built this way, what it costs, where it stops |

## Tools

[kind](https://kind.sigs.k8s.io/) ·
[Kro](https://kro.run/docs/overview/) ·
[multicluster-runtime](https://github.com/kubernetes-sigs/multicluster-runtime) ·
[Cluster Inventory API](https://github.com/kubernetes-sigs/cluster-inventory-api) ·
[KubeVirt](https://kubevirt.io/user-guide/) ·
[Rook](https://rook.io/docs/rook/latest-release/Getting-Started/intro/) ·
[Dex](https://dexidp.io/docs/) ·
[kubelogin](https://github.com/int128/kubelogin) ·
[Headlamp](https://headlamp.dev/docs/latest/) ·
[metrics-operator](https://github.com/openmcp-project/metrics-operator) ·
[Flux](https://fluxcd.io/flux/) ·
[Chainsaw](https://kyverno.github.io/chainsaw/latest/)

## Further reading

- Gregor Hohpe, [*Platform Strategy*](https://leanpub.com/platformstrategy), 2024.
- Körbächer, Grabner, Lipsig, [*Platform Engineering for Architects*](https://github.com/PacktPublishing/Platform-Engineering-for-Architects), Packt, 2024.
- CNCF TAG App Delivery, [*Platforms White Paper*](https://tag-app-delivery.cncf.io/whitepapers/platforms/).
- Skelton and Pais, [*Team Topologies*: thinnest viable platform](https://teamtopologies.com/key-concepts-content/what-is-a-thinnest-viable-platform-tvp).
- Kubernetes, [Multi-tenancy](https://kubernetes.io/docs/concepts/security/multi-tenancy/).
