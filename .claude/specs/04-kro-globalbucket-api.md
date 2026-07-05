# 04-kro-globalbucket-api Spec
# RED phase

## Goal
Kro RGD on hub expands GlobalBucket into RegionalBucketRequest per region.

## Acceptance Criteria
1. RGD manifest valid per Kro schema (spec fields use kro's simple-schema DSL, not nested OpenAPI maps)
2. RegionalBucketRequest CRD registered on hub before the RGD is applied (kro resolves resource templates via API discovery, not auto-generation)
3. kro's controller has RBAC (`kro-rbac.yaml`, aggregated via `rbac.kro.run/aggregate-to-controller`) for the platform.example.com group
4. Applying GlobalBucket{regions:[us]} creates RegionalBucketRequest
5. RegionalBucketRequest name follows deterministic naming: <gb-name>-<region>