# Nimbus

[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![CI](https://github.com/ziwon/nimbus/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ziwon/nimbus/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-informational)](#cross-compile)

Nimbus is a lightweight Zig control plane and agent for operating heterogeneous
edge AI, intermediary, server, and cloud nodes. One binary provides:

- a long-running agent with stable on-disk identity;
- interval, jitter, exponential retry, and graceful POSIX shutdown;
- labels and roles for targeting glasses, drones, vehicles, desktops, and servers;
- bounded NVIDIA and Jetson accelerator discovery with opaque stable IDs;
- a versioned desired-state and reconciliation loop;
- opt-in process, systemd, Docker, and containerd (nerdctl) runtime adapters;
- batched rollout, health gates, status history, and automatic rollback;
- SHA-256 artifact verification with optional Ed25519 signatures;
- separate node and administrative bearer tokens when configured;
- persistent node reports and heartbeat history in embedded SQLite;
- online/stale fleet views through the CLI and HTTP API;
- static Linux and native Windows/macOS cross-builds.

Agents and the CLI can connect to HTTPS endpoints. The embedded server listener
is HTTP-only, so terminate TLS at a reverse proxy for non-local deployments.
An unauthenticated server may bind only to loopback unless the explicitly unsafe
`--allow-insecure-no-auth` option is supplied.

## Requirements

- Just 1.43 or newer
- Zig 0.16.0
- Git, ShellCheck, and curl for the complete validation workflow
- Docker when using the container recipes

All project operations are defined in `justfile`. List them with:

```bash
just
```

The official redistributed Zig toolchain can be installed through Python:

```bash
just bootstrap
ZIG="python -m ziglang" just doctor
```

Set `ZIG="python -m ziglang"` when invoking other recipes if `zig` is not on
`PATH`. `just doctor` checks the local toolchain and reports optional Docker
availability.

## Quick start

Start the control plane:

```bash
just server
```

Start an agent in another terminal:

```bash
just agent
```

The default `.nimbus-node-id` file is created once and reused on later starts.
Use `--identity-file` to place it elsewhere, or `--id` for an explicit node ID.

Inspect the fleet:

```bash
just nodes
just node NODE_ID
```

Print a report without sending it:

```bash
just inspect
```

Run the discovery demonstration with `just demo`. On Linux, run the complete
process-runtime deployment, reconciliation, health, and deletion flow with:

```bash
just orchestration-demo
```

`scripts/build-all.sh` and `scripts/demo.sh` are thin wrappers around the
corresponding recipes.

## Project tasks

`justfile` is the canonical entry point for local development and CI:

| Area | Recipes |
|---|---|
| Setup | `just bootstrap`, `just doctor`, `just help` |
| Development | `just fmt`, `just build`, `just test`, `just check`, `just version` |
| Running Nimbus | `just server`, `just agent`, `just orchestrator`, `just inspect`, `just nodes`, `just node NODE_ID` |
| Desired state | `just deploy FILE`, `just deployments`, `just deployment NAME`, `just rollback NAME`, `just undeploy NAME` |
| Integration | `just demo`, `just api-check`, `just orchestration-demo`, `just integration`, `just run ARGS` |
| Release | `just release`, `just verify-static`, `just artifacts`, `just checksums` |
| Docker | `just docker-build`, `just docker-run`, `just docker-check` |
| Source control | `just git-status`, `just git-diff`, `just git-log`, `just pre-commit` |
| Cleanup | `just clean` |

Recipe parameters can override defaults. For example:

```bash
just server 0.0.0.0 9090 /var/lib/nimbus/nimbus.db node-token operator-token
just agent http://127.0.0.1:9090 server node-token
just deploy examples/deployments/process-demo.json http://127.0.0.1:9090 operator-token
just demo 19090 demo-token
IMAGE=registry.example/nimbus:dev just docker-build
```

`NIMBUS_SERVER`, `NIMBUS_TOKEN`, `ZIG`, and `IMAGE` are also honored where
applicable. Run `just --show RECIPE` to inspect the exact command before use.

## Configuration

Every operational command accepts a JSON configuration file with `--config`:

```json
{
  "server": "http://127.0.0.1:8080",
  "role": "smart-class",
  "labels": ["site=school-a", "device=desktop", "accelerator=jetson"],
  "node_id_file": "/var/lib/nimbus/node-id",
  "interval_seconds": 30,
  "jitter_seconds": 5,
  "retry_initial_seconds": 1,
  "retry_max_seconds": 30,
  "orchestration": true,
  "state_dir": "/var/lib/nimbus/state",
  "runtimes": "systemd,docker,containerd",
  "artifact_public_key": "HEX_ENCODED_ED25519_PUBLIC_KEY",
  "require_artifact_signatures": true,
  "max_artifact_bytes": 8589934592,
  "token_file": "/run/secrets/nimbus-node-token",
  "admin_token_file": "/run/secrets/nimbus-admin-token",
  "bind": "127.0.0.1",
  "port": 8080,
  "database": "nimbus.db",
  "stale_after_seconds": 90,
  "allow_insecure_no_auth": false
}
```

Precedence is command-line option, environment variable, configuration file,
then built-in default. Supported environment variables include:

- `NIMBUS_CONFIG`, `NIMBUS_SERVER`, `NIMBUS_TOKEN`, `NIMBUS_TOKEN_FILE`,
  `NIMBUS_ADMIN_TOKEN`, and `NIMBUS_ADMIN_TOKEN_FILE`;
- `NIMBUS_NODE_ID`, `NIMBUS_NODE_ID_FILE`, `NIMBUS_ROLE`, and `NIMBUS_LABELS`;
- `NIMBUS_INTERVAL_SECONDS`, `NIMBUS_JITTER_SECONDS`,
  `NIMBUS_RETRY_INITIAL_SECONDS`, and `NIMBUS_RETRY_MAX_SECONDS`;
- `NIMBUS_BIND`, `NIMBUS_PORT`, `NIMBUS_DATABASE`, and
  `NIMBUS_STALE_AFTER_SECONDS`, and `NIMBUS_ALLOW_INSECURE_NO_AUTH`;
- `NIMBUS_ORCHESTRATION`, `NIMBUS_RUNTIMES`, `NIMBUS_STATE_DIR`,
  `NIMBUS_ARTIFACT_PUBLIC_KEY`, `NIMBUS_REQUIRE_ARTIFACT_SIGNATURES`, and
  `NIMBUS_MAX_ARTIFACT_BYTES`.

Use separate configuration files for the server/operator and agent in real
deployments so the administrative token is never copied to managed nodes.

## HTTP API

`GET /healthz` and `GET /readyz` are public. Other endpoints require `Authorization: Bearer TOKEN`
when authentication is configured. `--token` protects agent routes;
`--admin-token` protects operator routes and falls back to `--token` when it is
not configured.

```text
POST /v1/heartbeat
GET  /v1/nodes
GET  /v1/nodes/{node_id}
GET  /v1/nodes/{node_id}/desired-state
POST /v1/nodes/{node_id}/workload-status
GET  /v1/deployments
PUT  /v1/deployments/{name}
GET  /v1/deployments/{name}
DELETE /v1/deployments/{name}
POST /v1/deployments/{name}/rollback
```

`GET /v1/nodes` accepts `limit=1..500` and an optional `after=NODE_ID` cursor,
and returns `{ "items": [...], "next_after": "..." | null }`.

Heartbeats are schema-versioned and validated before they are written. The
server accepts legacy v1 reports and v2 reports with a required accelerator
inventory; new agents emit v2. Upgrade the server before agents during a rolling
deployment. CPU-only discovery is distinct from a failed or unavailable probe.
SQLite always updates current node state, samples heartbeat history at most
every five minutes per node, retains it for seven days, and retains audit events
for 30 days. Enrollment is audited once instead of auditing every accepted
heartbeat.
The list and inspect endpoints calculate `online` or `stale` from the server's
receipt time and `--stale-after` threshold. Desired state, assignments, rollout
progress, and workload status history are persisted in the same database.

## Workload orchestration

Apply and inspect a deployment:

```bash
nimbus deployments apply examples/deployments/process-demo.json \
  --server http://127.0.0.1:8080 --token "$NIMBUS_ADMIN_TOKEN"
nimbus deployments list --server http://127.0.0.1:8080
nimbus deployments inspect process-demo --server http://127.0.0.1:8080
```

Enable only the runtimes a node is trusted to execute:

```bash
nimbus agent run --orchestrate --runtimes systemd,docker,containerd \
  --label site=school-a --label device=edge-server \
  --state-dir /var/lib/nimbus/state
```

Runtime adapters are deliberately allowlisted per agent:

| Runtime | Desired-state reference | Notes |
|---|---|---|
| `process` | Absolute argv or verified `{artifact}` | Linux bootstrap workloads; no shell expansion |
| `systemd` | Existing unit name | Uses `systemctl`; preferred for host processes |
| `docker` | Image pinned by `@sha256:` | Creates `nimbus-NAME` with Docker restart policy |
| `containerd` | Image pinned by `@sha256:` | Uses nerdctl in the `nimbus` namespace |

Targets may use node IDs, roles, `all`, or an AND set of labels. Rollouts have a
deterministic node order, bounded batch size, health-gated waves, an optional
pause, and an unavailable threshold. A failed wave automatically restores the
previous revision when `auto_rollback` is enabled. Deleting a deployment causes
agents to stop it on their next reconciliation.

See [Workload orchestration](docs/orchestration.md) for the schema, runtime
behavior, security controls, and production limitations.

## Cross-compile

```bash
just release
just verify-static
just artifacts
just checksums
```

Artifacts are written to:

```text
zig-out/releases/linux-x86_64/nimbus
zig-out/releases/linux-aarch64/nimbus
zig-out/releases/windows-x86_64/nimbus.exe
zig-out/releases/macos-x86_64/nimbus
zig-out/releases/macos-aarch64/nimbus
```

SQLite is compiled from the vendored public-domain amalgamation. Linux release
binaries use musl and remain statically linked.

## Deployment

The Docker image runs `nimbus server` and expects `/data` to be writable:

```bash
just docker-build
just docker-run
```

`just docker-check` builds the image, starts a disposable container, checks
`/healthz`, and verifies graceful shutdown.

The long-running systemd unit is at
`deploy/systemd/nimbus-agent.service`. Put secrets such as `NIMBUS_TOKEN` in
`/etc/nimbus/nimbus.env` rather than directly in the unit.

## Documentation

The [documentation index](docs/README.md) links to the
[architecture](docs/architecture.md),
[workload orchestration](docs/orchestration.md), and
[development](docs/development.md) guides. The root README focuses on setup and
operation; the documents describe internal design and contributor workflows.
