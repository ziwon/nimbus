# Nimbus Documentation

This directory contains design and contributor documentation for Nimbus.
The repository-level [README](../README.md) remains the primary entry point for
installation, commands, configuration, and day-to-day operation.

## Document map

| Document | Purpose | Primary audience |
|---|---|---|
| [Project README](../README.md) | Quick start, CLI usage, configuration, Just recipes, and deployment | Users and operators |
| [Architecture](architecture.md) | System boundaries, component responsibilities, data flow, persistence, and design trade-offs | Maintainers and reviewers |
| [Workload orchestration](orchestration.md) | Deployment schema, targeting, runtimes, reconciliation, rollout, artifacts, and security | Operators and platform engineers |
| [Development](development.md) | Project-specific Zig concepts, repository workflow, testing, debugging, and change checklists | Contributors |
| [SQLite vendoring notes](../third_party/sqlite/README.md) | Origin and licensing of the embedded SQLite amalgamation | Maintainers and release engineers |

## Suggested reading paths

### Running Nimbus

Start with the [project README](../README.md). It documents the supported
commands and the `justfile` interface without requiring knowledge of the
internals. Continue with [Workload orchestration](orchestration.md) before
enabling runtime adapters on managed nodes.

### Contributing code

Read [Development](development.md) first, then use
[Architecture](architecture.md) to understand the boundary affected by the
change.

### Reviewing a design change

Start with [Architecture](architecture.md), especially the component model,
state semantics, security boundary, and known limitations.

## Documentation boundaries

The root README is the concise user entry point. Architecture documents why
the system is shaped this way. Workload orchestration defines current operator
semantics and production boundaries. Development documents repository-specific
Zig practices and change workflows.

The docs describe implemented behavior, including desired-state reconciliation
and runtime deployment. Future GPU/resource scheduling, secrets, high
availability, and per-node identity should be documented as current behavior
only after their code and tests exist.
