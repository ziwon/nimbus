# Nimbus Workload Orchestration

## Scope

Nimbus uses a pull-based desired-state loop to deploy a small number of
well-defined workloads across edge AI devices, intermediary nodes, lightweight
servers, and cloud hosts. The goal is operational continuity on heterogeneous
fleets without requiring every device to run a Kubernetes node stack.

The implementation includes runtime control, reconciliation, health checks,
staged rollout, rollback, artifact integrity, and status history. It is not a
general container scheduler: it does not place workloads from resource
requests, provide a service network, attach distributed storage, or implement
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

Nimbus currently supports image, command, and restart policy. It does not yet
model ports, mounts, devices, GPU requests, networks, secrets, or resource
limits in the deployment schema.

## Reconciliation

After every successful heartbeat, an orchestration-enabled agent:

1. Fetches its desired-state document.
2. Strictly validates the schema and every deployment.
3. Loads its atomically stored applied-state record.
4. Stops workloads absent from desired state or marked `stopped`.
5. Keeps a matching healthy revision unchanged.
6. Restarts an unhealthy workload unless restart policy is `never`.
7. Stops the old revision, prepares the new artifact, and applies the runtime.
8. Runs the configured health check up to `failure_threshold` times.
9. Restores the previous local specification if the new apply fails.
10. Reports observed state and atomically saves the new local state.

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

`inspect` returns rollout configuration, the canonical specification, and each
node assignment with wave, observed revision, state, message, and update time.
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
