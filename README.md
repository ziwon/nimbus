# Nimbus

[![Zig 0.16.0](https://img.shields.io/badge/Zig-0.16.0-F7A41D?logo=zig&logoColor=white)](https://ziglang.org/)
[![CI](https://github.com/ziwon/nimbus/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ziwon/nimbus/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-informational)](#cross-compile)

Nimbus is a lightweight Zig agent and control plane for discovering and
monitoring heterogeneous edge, server, desktop, and cloud nodes. One binary
provides:

- a long-running agent with stable on-disk identity;
- interval, jitter, exponential retry, and graceful POSIX shutdown;
- a bearer-token-protected HTTP control plane;
- persistent node reports and heartbeat history in embedded SQLite;
- online/stale fleet views through the CLI and HTTP API;
- static Linux and native Windows/macOS cross-builds.

The transport is plain HTTP in this early version. Terminate TLS at a reverse
proxy for non-local deployments.

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

Run the complete local demonstration with `just demo`.
`scripts/build-all.sh` and `scripts/demo.sh` are thin wrappers around the
corresponding recipes.

## Project tasks

`justfile` is the canonical entry point for local development and CI:

| Area | Recipes |
|---|---|
| Setup | `just bootstrap`, `just doctor`, `just help` |
| Development | `just fmt`, `just build`, `just test`, `just check`, `just version` |
| Running Nimbus | `just server`, `just agent`, `just inspect`, `just nodes`, `just node NODE_ID` |
| Integration | `just demo`, `just run ARGS` |
| Release | `just release`, `just verify-static`, `just artifacts`, `just checksums` |
| Docker | `just docker-build`, `just docker-run`, `just docker-check` |
| Source control | `just git-status`, `just git-diff`, `just git-log`, `just pre-commit` |
| Cleanup | `just clean` |

Recipe parameters can override defaults. For example:

```bash
just server 0.0.0.0 9090 /var/lib/nimbus/nimbus.db local-token
just agent http://127.0.0.1:9090 server local-token
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
  "role": "edge",
  "node_id_file": "/var/lib/nimbus/node-id",
  "interval_seconds": 30,
  "jitter_seconds": 5,
  "retry_initial_seconds": 1,
  "retry_max_seconds": 30,
  "token": "development-token",
  "bind": "127.0.0.1",
  "port": 8080,
  "database": "nimbus.db",
  "stale_after_seconds": 90
}
```

Precedence is command-line option, environment variable, configuration file,
then built-in default. Supported environment variables include:

- `NIMBUS_CONFIG`, `NIMBUS_SERVER`, and `NIMBUS_TOKEN`;
- `NIMBUS_NODE_ID`, `NIMBUS_NODE_ID_FILE`, and `NIMBUS_ROLE`;
- `NIMBUS_INTERVAL_SECONDS`, `NIMBUS_JITTER_SECONDS`,
  `NIMBUS_RETRY_INITIAL_SECONDS`, and `NIMBUS_RETRY_MAX_SECONDS`;
- `NIMBUS_BIND`, `NIMBUS_PORT`, `NIMBUS_DATABASE`, and
  `NIMBUS_STALE_AFTER_SECONDS`.

## HTTP API

`GET /healthz` is public. When a token is configured, all other endpoints
require `Authorization: Bearer TOKEN`.

```text
POST /v1/heartbeat
GET  /v1/nodes
GET  /v1/nodes/{node_id}
```

Heartbeats are schema-versioned and validated before they are written. SQLite
stores the current node record, full heartbeat history, and basic audit events.
The list and inspect endpoints calculate `online` or `stale` from the server's
receipt time and `--stale-after` threshold.

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
[architecture](docs/architecture.md) and
[development](docs/development.md) guides. The root README focuses on setup and
operation; the documents describe internal design and contributor workflows.
