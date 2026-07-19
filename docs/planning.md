# AI Accelerator Planning

This document defines the direction for AI accelerator support in Nimbus. It is
a product and engineering roadmap, not a promise that every item belongs in the
next release.

Nimbus should orchestrate AI workloads without becoming an inference engine.
TensorRT, ONNX Runtime, OpenVINO, llama.cpp, vendor SDKs, and application
processes remain external runtimes. Nimbus discovers accelerator capabilities,
selects compatible artifacts, assigns devices, and keeps those workloads in the
declared state.

## Target environments

The design must work across a heterogeneous edge-to-cloud topology:

- smart glasses, drones, robots, and vehicles with constrained SoCs;
- classroom or site desktops acting as aggregation nodes;
- Jetson-class edge servers and compact GPU servers;
- control-plane servers without accelerators;
- cloud GPU workers that may be intermittent or expensive.

The common abstraction is an **accelerator**, not only a GPU. Initial kinds are
GPU, NPU, DLA, TPU, DSP, and vendor AI ASICs.

## Product principles

1. **Capability before scheduling.** Inventory must be trustworthy before the
   control plane makes placement decisions.
2. **Stable identity.** A physical or partitioned device needs a stable ID that
   survives agent restarts.
3. **Portable desired state.** Deployment specifications describe requirements,
   not vendor-specific command-line flags.
4. **Runtime isolation.** Device access is explicit and least-privileged.
5. **Offline safety.** Edge workloads continue according to a declared lease or
   offline policy when the control plane is unreachable.
6. **Artifact integrity.** Models, engines, and binaries use digests and optional
   signatures before activation.
7. **Incremental scope.** Nimbus will not reproduce Kubernetes scheduling,
   networking, or storage APIs.

## Existing foundation

Nimbus already provides the generic mechanisms required by this roadmap:

- node identity, heartbeat, roles, and labels;
- desired-state retrieval and reconciliation;
- process, systemd, Docker, and containerd adapters;
- digest-pinned artifacts and optional Ed25519 verification;
- staged rollout, health checks, rollback, and workload status history.

Today an operator can manually label a node with `accelerator=jetson` and target
it. Nimbus does not yet discover devices, measure capacity, reserve a device, or
inject it into a runtime.

## Non-goals

- implementing model inference inside Nimbus;
- training jobs, distributed training collectives, or notebook management;
- fractional GPU sharing before the underlying vendor provides safe isolation;
- transparent migration of running accelerator memory;
- Kubernetes API compatibility;
- a universal abstraction for every vendor feature in the first schema.

## Phase 0: fleet security and resilience

Accelerator control expands the impact of a compromised control plane. The
following foundation gates accelerator assignment:

- HTTPS-capable clients and fail-closed authentication defaults;
- bounded request duration and bounded server concurrency;
- secret-file support rather than requiring credentials in process arguments;
- heartbeat retention and paginated inventory;
- per-node credentials and rotation before multi-tenant production use;
- signed desired-state documents before privileged device assignment.

Shared fleet tokens remain suitable only for small trusted deployments.

## Phase 1: accelerator inventory

Heartbeat schema version 2 includes detected accelerators. Static
identity and slowly changing capability data belong in heartbeat inventory;
high-frequency utilization belongs in a separate sampled telemetry path.

Implemented inventory shape:

```json
{
  "accelerator_inventory": {
    "schema_version": 1,
    "status": "complete",
    "accelerators": [{
      "id": "gpu:nvidia:7f3c...",
      "kind": "gpu",
      "vendor": "NVIDIA",
      "model": "NVIDIA GPU",
      "source": "nvidia-smi",
      "availability": "available",
      "memory_total_bytes": 8589934592,
      "driver_version": "...",
      "runtimes": [],
      "capabilities": ["compute_capability=8.7"]
    }],
    "probes": [{
      "name": "nvidia-smi",
      "status": "ok",
      "devices_found": 1,
      "error_name": null
    }]
  }
}
```

Inventory rules:

- `id` is stable and opaque; raw device paths are not identities.
- Unknown vendor fields are omitted until the bounded schema explicitly
  supports them.
- Probe failure reports `unavailable` with a reason; it must not silently turn
  an accelerator node into a CPU-only node.
- Sensitive serial numbers are hashed or omitted by default.

The A1 providers are a bounded `nvidia-smi` probe and a Jetson system-file
fallback that discovers the integrated GPU and numbered DLA devices. Future
provider order is:

1. NVIDIA NVML when it can preserve static-build and timeout guarantees;
2. Intel Level Zero;
3. AMD ROCm SMI;
4. plugin probes for Coral, Hailo, Rockchip, and other edge NPUs.

Each probe implements a small interface and runs with a time and output bound.
A failed optional vendor library must not prevent the agent from starting.

## Phase 2: declarative accelerator requirements

Add optional requirements to a deployment:

```json
{
  "resources": {
    "accelerators": {
      "count": 1,
      "kind": "gpu",
      "vendor": "nvidia",
      "memory_min_bytes": 4294967296,
      "capabilities": ["fp16"]
    }
  }
}
```

Labels continue to express operator intent such as site, environment, and
device class. Accelerator requirements express machine capabilities. Operators
should not need to maintain facts such as GPU memory in labels.

The first scheduler is deliberately simple:

- filter explicit node, role, and label targets;
- reject nodes that do not satisfy accelerator requirements;
- choose a deterministic compatible device on each targeted node;
- report `unschedulable` with a machine-readable reason;
- do not overcommit devices.

Capacity-aware placement across an unspecified pool is deferred until inventory
and reservations have proven reliable.

## Phase 3: runtime device injection

The reconciler creates a local reservation before starting a workload and
releases it only after the runtime has stopped.

- Docker and containerd should prefer the Container Device Interface (CDI) so
  vendor-specific flags do not leak into the deployment schema.
- systemd and process runtimes receive an explicit allowlist of device paths and
  environment variables.
- runtime adapters must never infer access to all host accelerators.
- reconciliation verifies that the recorded device still exists and belongs to
  the expected workload before restart or termination.

MIG, SR-IOV, and vendor partitions are represented as independent accelerator
IDs only when the vendor exposes a stable isolation boundary.

## Phase 4: AI artifact lifecycle

A deployment may declare platform and accelerator-specific variants:

```text
model.onnx                 portable source model
engine-linux-x86_64-cuda   NVIDIA server engine
engine-linux-aarch64-jetson Jetson engine
model-openvino             Intel optimized model
```

The agent selects the most specific compatible variant, verifies its digest and
signature, stores it in a size-bounded local cache, and activates it atomically.
Rollout health includes download, verification, load/warm-up, and application
readiness as separate states. A failed optimized variant may use a declared CPU
fallback; fallback is never implicit.

## Phase 5: edge-aware placement

After static allocation is stable, add dynamic constraints:

- free accelerator memory and active reservations;
- temperature and thermal throttling;
- power source and power budget;
- connectivity quality and offline duration;
- model cache locality;
- cloud cost or operator-defined priority.

Dynamic telemetry is sampled and bounded. It does not create heartbeat history
at device polling frequency. Scheduling decisions record their inputs and
reason so operators can understand placement.

## Offline and safety policy

Accelerator workloads need an explicit disconnection policy:

```text
continue     keep the last verified desired state
lease        continue until a signed lease expires
stop         terminate after the offline deadline
```

Safety-critical vehicle or drone applications should normally use a locally
approved `continue` or lease policy. Nimbus must not terminate a control or
perception workload merely because a WAN link dropped unless the deployment
explicitly requests that behavior.

## Security considerations

- Device assignment is a privileged operation and requires a runtime allowlist.
- Probe subprocesses have bounded execution, sanitized environments, and no
  shell interpolation.
- Accelerator identifiers and telemetry are authenticated node claims; the
  long-term design binds them to per-node credentials.
- Artifact signatures cover the selected variant and its compatibility
  metadata.
- Reservation and deployment changes are audit events; utilization samples are
  telemetry, not audit records.

## Milestones and acceptance criteria

### A1 — Inventory

**Status: software complete (2026-07-19).** Heartbeat v2, bounded providers,
trust-boundary validation, raw report persistence, node inspection, and v1/v2
coexistence are implemented. Fixture tests cover CPU-only, missing providers,
timeout outcomes, malformed output, disappearance, and Jetson GPU/DLA IDs. An
NVIDIA RTX host was smoke-tested for repeatable opaque identity. Jetson hardware
qualification across reboot remains open and must complete before A2 is used on
production Jetson nodes.

- NVIDIA and Jetson probes return stable, schema-versioned inventory.
- CPU-only and missing-driver systems remain functional.
- probe timeout, malformed output, and device disappearance have tests.

### A2 — Requirements and reservation

- incompatible nodes are rejected with a precise reason;
- a device cannot be assigned to two exclusive workloads;
- reservations recover safely after agent restart.

### A3 — Runtime integration

- Docker/containerd receive only the reserved CDI devices;
- process/systemd adapters expose only declared device access;
- stop, upgrade, rollback, and crash recovery release reservations correctly.

### A4 — Model lifecycle

- variant selection is deterministic and tested across CPU, Jetson, and GPU;
- cache eviction never removes an active artifact;
- signature failure prevents activation and triggers rollout failure policy.

### A5 — Placement

- placement is explainable and deterministic for equal inputs;
- offline, thermal, capacity, and cost policies have simulation tests;
- no scheduling loop depends on unbounded or high-frequency database growth.

## First implementation slice

The first accelerator pull request should contain only:

1. heartbeat schema v2 with the generic accelerator inventory type;
2. a probe registry and a deterministic fake probe for tests;
3. an NVIDIA/Jetson probe behind an explicit build or runtime capability;
4. storage and node-inspection support for inventory;
5. documentation and fixture-based tests.

It should not allocate devices or change deployment scheduling. That separation
lets us validate inventory accuracy on real edge hardware before desired state
can grant privileged accelerator access.
