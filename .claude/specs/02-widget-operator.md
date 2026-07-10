# 02-widget-operator Spec
# RED phase — define what must be true before implementation starts

## Goal
A minimal, real (non-mock) reconciler on `us`: a `Widget` CRD + controller that flips status after a short delay, standing in for whatever a real downstream integration would be.

## Acceptance Criteria
1. `Widget` CRD installed on `us` (group `platform.example.com/v1alpha1`; `spec.message`, `status.phase`, `status.endpoint`)
2. Applying a `Widget` transitions `status.phase: Pending -> Ready` within a few seconds (delay is config-driven, not hardcoded)
3. `status.endpoint` is populated once `Ready`
4. Operator runs as a normal single-cluster controller-runtime controller (no multicluster-runtime dependency here — that's the binding controller's job)
