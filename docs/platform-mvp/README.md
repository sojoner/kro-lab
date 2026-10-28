# Documentation

Architecture and operations reference for the platform. Start with the [Architecture](architecture.md), then the [Domain model](domain-model.md), which defines the vocabulary the other documents use.

## Concepts

| Document | Covers |
|----------|--------|
| [Architecture](architecture.md) | System context, components, multi-cluster runtime, key decisions |
| [Domain model](domain-model.md) | Ubiquitous language, bounded contexts, aggregates, domain services, layering |
| [Multi-tenancy](multi-tenancy.md) | Tenant label, namespaces, role tiers |
| [Identity and trust](identity-and-trust.md) | Projected service account tokens, Dex, `AuthenticationConfiguration`, spoke authorization |
| [Admission guardrails](admission-guardrails.md) | `ValidatingAdmissionPolicy` resources that protect platform configuration |

## Services

| Document | Covers |
|----------|--------|
| [Virtual machines](virtual-machines.md) | `VmSet` orders, KubeVirt on the VM host |
| [Object storage](object-storage.md) | `Bucket` orders, Rook and Ceph RADOS Gateway on the storage host |

## Components

| Document | Covers |
|----------|--------|
| [Ordering API](ordering-api.md) | Kro resource graphs and the regional request CRDs |
| [Placement controllers](placement-controllers.md) | VM and bucket binding controllers |
| [Fleet inventory](fleet-inventory.md) | `ClusterProfile`, labels and the multicluster provider |
| [Observability](observability.md) | Metrics, logs, dashboards, continuous verification |

## Operations

| Document | Covers |
|----------|--------|
| [Build and deploy](build-and-deploy.md) | Repository layout, deploy waves, trust bootstrap order, development loop |
| [Local topology](local-topology.md) | The kind clusters |
| [Adding a region](adding-a-region.md) | Registering a region or a service host |
| [Testing](testing.md) | The end-to-end suite and in-cluster verification |

## Overview

| Document | Covers |
|----------|--------|
| [Capabilities](capabilities.md) | What the platform offers, roles, known limits |
| [Use cases](use-cases.md) | Scenarios per role, with flows |
