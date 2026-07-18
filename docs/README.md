# Nimbus Documentation

This directory contains design and contributor documentation for Nimbus.
The repository-level [README](../README.md) remains the primary entry point for
installation, commands, configuration, and day-to-day operation.

## Document map

| Document | Purpose | Primary audience |
|---|---|---|
| [Project README](../README.md) | Quick start, CLI usage, configuration, Just recipes, and deployment | Users and operators |
| [Architecture](architecture.md) | System boundaries, component responsibilities, data flow, persistence, and design trade-offs | Maintainers and reviewers |
| [Development](development.md) | Project-specific Zig concepts, repository workflow, testing, debugging, and change checklists | Contributors |
| [SQLite vendoring notes](../third_party/sqlite/README.md) | Origin and licensing of the embedded SQLite amalgamation | Maintainers and release engineers |

## Suggested reading paths

### Running Nimbus

Start with the [project README](../README.md). It documents the supported
commands and the `justfile` interface without requiring knowledge of the
internals.

### Contributing code

Read [Development](development.md) first, then use
[Architecture](architecture.md) to understand the boundary affected by the
change.

### Reviewing a design change

Start with [Architecture](architecture.md), especially the component model,
state semantics, security boundary, and known limitations.

## Documentation boundaries

The current documentation describes the implemented Nimbus foundation:

- one Zig executable containing the CLI, agent, and control plane;
- agent-initiated HTTP heartbeat delivery;
- stable local node identity;
- bearer-token authentication for development deployments;
- SQLite-backed node state, heartbeat history, and audit events;
- five cross-compiled release targets.

GPU discovery, desired-state reconciliation, runtime deployment, and OTA
updates are not implemented. They should be documented as current behavior only
after their code and tests exist.

When the protocol or security surface becomes large enough to evolve
independently, add focused `protocol.md` and `security.md` documents and link
them from this index.
