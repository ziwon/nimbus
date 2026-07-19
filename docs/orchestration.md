# Nimbus Workload Orchestration

## Scope

Nimbus uses a pull-based desired-state loop to deploy a small number of
well-defined workloads across edge AI devices, intermediary nodes, lightweight
servers, and cloud hosts. The goal is operational continuity on heterogeneous
fleets without requiring every device to run a Kubernetes node stack.

The implementation includes runtime control, reconciliation, health checks,
staged rollout, rollback, artifact integrity, status history, and exclusive
accelerator reservation within explicitly targeted nodes. It is not a general
container scheduler: it does not choose nodes from an unspecified resource
pool, provide a service network, attach distributed storage, or implement
Kubernetes API compatibility.

## Topology model

Every managed node has a stable ID, one role, and zero or more labels. A useful
edge-to-cloud layout is:

| Tier | Example role | Example labels | Typical runtime |
|---|---|---|---|
| Device | `glasses`, `drone`, `vehicle` | `site`, `model`, `accelerator` | systemd or process |
| Intermediary | `smart-class`, `edge-gateway` | `site`, `zone`, `device=desktop` | Docker or containerd |
| Edge server | `edge-server` | `site`, `rack`, `accelerator` | containerd or Docker |
| Control plane | `control-plane` | `region`, `environment` | systemd or container |
| Cloud worker | `cloud-worker` | `region`, `gpu`, `environment` | container runtime |

Agents initiate all control-plane connections. A node behind NAT needs outbound
access to the Nimbus API and artifact source, but no inbound management port.

## Enable an agent

Workload execution is disabled by default. Enable it with an explicit runtime
allowlist and persistent state directory:

```bash
nimbus agent run \
  --server https://nimbus.example \
  --token "$NIMBUS_NODE_TOKEN" \
  --role edge-server \
  --label site=school-a \
  --label accelerator=jetson \
  --orchestrate \
  --runtimes systemd,containerd \
  --state-dir /var/lib/nimbus/state
```

Equivalent configuration keys are `orchestration`, `runtimes`, `state_dir`,
and `labels`. The local `applied.json` file is replaced atomically after a
successful reconciliation pass. Do not share one state directory between
agents.

## Deployment document

Deployment JSON is schema-versioned. This process example targets all matching
labels and rolls out ten nodes at a time:

```json
{
  "schema_version": 1,
  "name": "vision-inference",
  "revision": 3,
  "desired": "running",
  "runtime": {
    "kind": "process",
    "reference": null,
    "command": ["{artifact}", "--listen", "127.0.0.1:9000"],
    "working_directory": "/var/lib/vision"
  },
  "artifact": {
    "source": "http://artifacts.internal/vision-inference-v3",
    "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "signature_ed25519": null
  },
  "resources": {
    "accelerators": {
      "count": 1,
      "kind": "gpu",
      "vendor": "nvidia",
      "memory_min_bytes": 4294967296,
      "capabilities": ["fp16"]
    }
  },
  "health_check": {
    "kind": "http",
    "target": "http://127.0.0.1:9000/healthz",
    "command": [],
    "timeout_seconds": 5,
    "failure_threshold": 3
  },
  "restart_policy": "always",
  "targets": {
    "all": false,
    "node_ids": [],
    "roles": [],
    "labels": [
      { "key": "site", "value": "school-a" },
      { "key": "accelerator", "value": "jetson" }
    ]
  },
  "rollout": {
    "batch_size": 10,
    "max_unavailable": 1,
    "pause_seconds": 30,
    "auto_rollback": true
  }
}
```

Apply it with an operator credential:

```bash
nimbus deployments apply deployment.json \
  --server https://nimbus.example \
  --token "$NIMBUS_ADMIN_TOKEN"
```

Names contain only ASCII letters, digits, `.`, `_`, and `-`. Revisions are
positive and must increase for each update. Unknown JSON fields are rejected.

## Target selection

Node IDs, roles, and `all` are OR selectors. All label selectors in one
deployment must match the node, so labels form an AND selector. A node is
selected if any ID/role/all selector matches or if its labels satisfy the
complete label set.

When a deployment is applied, the control plane sorts currently registered
matching nodes by node ID and stores their wave assignments. This prevents
polling order from bypassing batch limits. A matching node that registers
later is assigned when it first requests desired state. After a rollout is
complete, newly matching nodes receive the completed revision directly.

Assignments remain attached to their node for the lifetime of that deployment
revision, even if the node is relabeled during rollout. This keeps a wave from
losing a member and stalling. New deployments and newly applied revisions use
the latest role and labels when rebuilding assignments.

## Accelerator requirements and reservations

`resources.accelerators` declares a positive `count`, a required accelerator
`kind`, and optional `vendor`, minimum total memory, and capability strings.
The declaration describes hardware compatibility; labels continue to describe
operator intent such as site or device class.

A heartbeat v3 agent advertises `accelerator-requirements-v1`. For each matching
node, the control plane filters the normalized inventory, excludes IDs reserved
by other deployments, sorts compatible IDs lexically, and reserves the required
count atomically. The database uniqueness key is `(node_id, accelerator_id)`, so
two workloads cannot own one exclusive device. The assignment is also persisted
in the agent's canonical `applied.json` ledger and recovered after restart.

New placement fails closed unless inventory is `complete`. An existing
compatible reservation is retained when a later inventory is `partial` or
`unavailable`; only a `complete` report can confirm that the assigned device is
missing or incompatible. Deployment inspection exposes reservations and
machine-readable placement reasons such as `agent_feature_unsupported`,
`no_accelerator`, `accelerator_memory_insufficient`,
`accelerator_capability_missing`, and `accelerator_capacity_exhausted`.

This A2 reservation is logical ownership, not device access. Until A3 adds CDI
and host-device injection, the agent preserves any existing applied workload
and reports `accelerator_assignment_unavailable` when placement is blocked. If
an assignment is ready, it validates and saves the assignment but reports
`runtime_device_injection_unavailable`. In both cases it does not start the
accelerator workload. Do not treat the current reservation as production GPU or
DLA isolation.

## Runtime adapters

### Process

The process adapter runs an argv array directly and never invokes a shell. The
first argument must be an absolute path or `{artifact}`. It is supported on
Linux and records both PID and Linux process start-time ticks, preventing a
stale state record from terminating an unrelated process after PID reuse.

The adapter is suitable for bootstrap and appliance-style workloads. Prefer
systemd when a host service needs richer dependency, logging, user, cgroup, or
restart policy management.

### systemd

The systemd adapter accepts an existing unit name and calls `systemctl restart`,
`is-active`, and `stop`. Nimbus does not generate or edit unit files. Provision
units, users, sandboxing, environment files, and resources with the host image
or another trusted installation path.

### Docker and containerd

Container references must include `@sha256:`; mutable tags such as `latest` are
rejected. Docker uses `docker`, while the containerd adapter uses `nerdctl` in
the `nimbus` namespace. Both create a deterministic `nimbus-NAME` container and
translate the desired restart policy.

Nimbus currently supports image, command, restart policy, and accelerator
requirements. It does not yet inject CDI/device access or model ports, mounts,
networks, secrets, or general resource limits in the deployment schema.

## Reconciliation

After every successful heartbeat, an orchestration-enabled agent:

1. Fetches its desired-state document.
2. Strictly validates every deployment and accelerator assignment.
3. Validates assignments against the same inventory snapshot as the heartbeat.
4. Loads its atomically stored applied state and accelerator ledger.
5. Stops workloads absent from desired state or marked `stopped`.
6. Blocks accelerator workloads before runtime execution until A3 is available.
7. Keeps a matching healthy CPU revision unchanged.
8. Restarts an unhealthy CPU workload unless restart policy is `never`.
9. Stops the old revision, prepares the new artifact, and applies the runtime.
10. Runs the configured health check up to `failure_threshold` times.
11. Restores the previous local specification if the new apply fails.
12. Reports observed state and atomically saves both local records.

Observed states are `pending`, `applying`, `healthy`, `degraded`, `failed`,
`stopped`, and `blocked`. A runtime outside the agent allowlist reports
`blocked` and is not executed.

## Health checks

| Kind | Behavior |
|---|---|
| `runtime` | Process identity, active systemd unit, or running container |
| `http` | HTTP GET; any 2xx or 3xx response is healthy |
| `tcp` | Connect to a numeric `host:port` before the timeout |
| `command` | Run an absolute direct argv and require exit status zero |

Command checks do not use a shell. Runtime HTTP checks currently support
`http://`; use loopback health endpoints and terminate external TLS at the
network boundary.

## Rollout and rollback

Only the current wave receives a new revision. Nodes in later waves continue
to receive the previous revision. A wave advances after all its assignments
report the desired revision as `healthy` or `stopped`. If `pause_seconds` is
nonzero, the pause begins after the wave becomes healthy.

When failed or degraded assignments in the current wave reach
`max_unavailable`, the deployment is marked failed. If `auto_rollback` is true
and a previous specification exists, the control plane restores it, resets all
assignments, and agents reconcile back to that revision. Operators may also
run:

```bash
nimbus deployments rollback vision-inference
```

Deleting a deployment removes it from desired state. Each selected agent stops
its local workload during its next successful reconciliation.

## Artifact integrity and signatures

Process artifacts support absolute `file://` and plain `http://` sources. The
agent streams into a temporary file while enforcing `max_artifact_bytes`,
verifies SHA-256, marks the file executable, and atomically renames it into a
revision-specific path. A digest mismatch never replaces the cached artifact.

For signature enforcement, sign the lowercase 64-character SHA-256 string with
Ed25519, put the hex signature in `signature_ed25519`, and configure agents with:

```bash
--artifact-public-key HEX_PUBLIC_KEY --require-artifact-signatures
```

The public key is 32 bytes encoded as 64 hex characters; the signature is 64
bytes encoded as 128 hex characters. Digest pinning is always required for an
artifact. Signature enforcement is an agent-side policy, so a compromised
control plane cannot disable it in desired state.

## Authentication and transport

Use `--token`/`NIMBUS_TOKEN` or `--token-file`/`NIMBUS_TOKEN_FILE` for agent
routes and the corresponding administrative options for operator routes. If no administrative
token is configured, Nimbus falls back to the node token for compatibility.
Production deployments should always separate them and keep the administrative
credential off managed nodes.

Agents and the CLI can use HTTPS, while the embedded server listens on HTTP.
Place it behind a TLS reverse proxy or a private authenticated network. A
non-loopback server without authentication fails closed unless the explicit
insecure override is used. The shared node token does not provide
per-device identity: any holder can submit status for another node ID. Per-node
credentials, rotation, mTLS, scoped authorization, and signed desired-state
documents remain future security work.

## Operational commands

```text
nimbus deployments apply FILE
nimbus deployments list
nimbus deployments inspect NAME
nimbus deployments delete NAME
nimbus deployments rollback NAME
```

`inspect` returns rollout configuration, the canonical specification, placement
decisions and reservations, and each node assignment with wave, observed
revision, state, message, and update time.
Workload status history is retained in SQLite for 30 days for future querying
but does not yet have a dedicated CLI endpoint. Heartbeat history is separately
sampled and retained for seven days.

## Production boundaries

Nimbus is useful when workloads and topology are known and small operational
surface area matters more than Kubernetes compatibility. Before relying on it
for safety-critical vehicles or drones, add device-specific watchdogs,
redundant control planes, offline rollout policy, secure boot/attestation,
hardware health inventory, and fault-injection testing. Nimbus does not replace
a flight controller, vehicle safety controller, or hardware fail-safe.

The current control plane is one process with one SQLite database. Requests are
handled concurrently while database transactions are serialized with an
I/O-aware mutex. Backup, replication, leader election, multi-region failover,
and horizontally scaled control-plane coordination are not implemented. An
offline node in the current wave also has no automatic timeout/skip policy;
operators must recover it or explicitly roll back/delete the deployment.
