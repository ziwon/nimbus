# Developing Nimbus

## Audience and scope

This guide is for contributors working on Nimbus. It introduces the parts of
Zig that appear in this repository and describes the local workflow, testing
strategy, and safe ways to evolve the CLI, heartbeat schema, storage model, and
platform support.

It is not a general Zig tutorial. Read it alongside the source and the
[architecture document](architecture.md).

## Prerequisites

The repository currently expects:

- Just 1.43 or newer;
- Zig 0.16.0;
- Git and ShellCheck for the check pipeline;
- curl for local integration and container health checks;
- Docker for container recipes.

Inspect the available tasks and local tools:

```bash
just
just doctor
```

If `zig` is not installed on `PATH`, install the pinned Python distribution:

```bash
just bootstrap
ZIG="python -m ziglang" just doctor
```

Pass the same `ZIG` value to other recipes in that environment.

## Daily workflow

The shortest useful edit loop is:

```bash
just fmt
just test
just check
```

Before committing a change that can affect portability or the release graph:

```bash
just pre-commit
```

`pre-commit` verifies formatting, shell wrappers, unit tests, Git whitespace,
all five cross-builds, and static Linux linkage. CI runs the closely related
`just ci` pipeline and also generates release checksums.

Useful focused commands include:

```bash
just demo
just orchestration-demo
just run --version
just inspect
just docker-check
just git-status
just git-diff
```

## Repository layout

```text
build.zig                     Zig build and cross-release graph
build.zig.zon                 Package metadata and included paths
justfile                      Canonical development and operations tasks
src/main.zig                  Process entry point and CLI dispatch
src/agent.zig                 Agent heartbeat and reconciliation lifecycle
src/client.zig                HTTP client operations
src/config.zig                JSON and environment configuration
src/heartbeat.zig             Heartbeat schema and local collection
src/identity.zig              Stable node identity
src/orchestration.zig         Desired-state types and validation
src/reconciler.zig            Local desired/current reconciliation
src/runtime.zig               Runtime adapters and artifact verification
src/server.zig                HTTP control plane
src/shutdown.zig              Signal and shutdown coordination
src/storage.zig               SQLite persistence
third_party/sqlite/           Vendored SQLite amalgamation
deploy/systemd/               Agent service unit
scripts/                      Compatibility wrappers around Just recipes
docs/                         Design and contributor documentation
examples/deployments/         Runnable desired-state examples
```

## Zig concepts used in Nimbus

### Explicit allocators and lifetimes

Nimbus has no garbage collector. Functions that allocate receive or obtain an
allocator and make ownership visible in the call site.

The process entry point exposes two important allocators:

- `init.gpa` is used for allocations that are explicitly freed during a
  command or request.
- `init.arena` is used for values that may live until process exit, such as
  parsed CLI arguments, configuration strings, and node identity.

A common pattern is:

```zig
const payload = try heartbeat.serializeAlloc(init.gpa, value);
defer init.gpa.free(payload);
```

Use the arena only when process-lifetime ownership is intentional. Do not use
it to hide unbounded allocation in a request or loop.

The configuration parser uses `.allocate = .alloc_always`. This is required
because parsed strings must outlive the temporary file buffer. Borrowing those
strings would create dangling slices after `load` returns.

### Error unions and cleanup

Zig functions returning `!T` produce either `T` or an error. Nimbus uses:

- `try` to propagate errors when the caller owns the policy;
- `catch` and `switch` when behavior differs by error;
- `defer` for unconditional cleanup;
- `errdefer` for rollback on a failing path.

The storage transaction is the clearest example:

```zig
try self.exec("BEGIN IMMEDIATE;");
errdefer self.exec("ROLLBACK;") catch {};
// writes
try self.exec("COMMIT;");
```

Prefer specific local recovery over converting every failure into logging and
continuation. An accepted heartbeat must be fully persisted or rolled back.

### Slices and C strings

Most Zig strings are `[]const u8`: a pointer and a length, not a null-terminated
C string. SQLite paths require a sentinel-terminated value, so storage creates
one with `dupeZ` before calling `sqlite3_open_v2`.

SQLite column text is valid only while the prepared statement remains on the
current row. Serialize or copy it before stepping or finalizing the statement.

### `defer` as resource structure

Files, HTTP clients, sockets, prepared statements, listeners, and SQLite
handles are paired with cleanup near acquisition. Keep this structure when
editing a function:

```zig
var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
defer file.close(init.io);
```

This keeps early returns and propagated errors safe without a separate cleanup
section.

### Compile-time target information

`heartbeat.zig` imports `builtin` and derives OS, CPU architecture, and ABI from
the selected compilation target. This means cross-built reports describe the
artifact target without runtime platform tables.

Platform-specific branches should use compile-time conditions where possible,
as `shutdown.zig` does for POSIX signal registration.

### `std.Io` and process initialization

Nimbus uses the Zig 0.16 `std.process.Init` and `std.Io` interfaces. File,
network, clock, randomness, and sleep operations receive `init.io`. Preserve
that dependency rather than mixing in older standard-library APIs from examples
written for other Zig versions.

The server uses `std.Io.Group.concurrent` for connection tasks and
`init.io.concurrent` for the shutdown monitor. The registry protects its one
SQLite connection and multi-statement transactions with `std.Io.Mutex`; keep
lock acquisition outside transaction begin/commit boundaries.

### C interoperability

`storage.zig` imports SQLite through:

```zig
const c = @cImport({
    @cInclude("sqlite3.h");
});
```

`build.zig` adds the header path, compiles `sqlite3.c`, and links libc for every
target. Keep SQLite compile flags centralized in the build file. Do not add a
system SQLite dependency unless the release and container portability model is
deliberately changed.

### Tests live with the code

Unit tests are declared in the relevant Zig files and reached through the test
block in `main.zig`. Add small deterministic tests next to pure validation,
serialization, retry, path, and storage logic.

Use an in-memory SQLite database for storage unit tests. Use `just demo` for the
discovery path and `just orchestration-demo` for the Linux process-runtime path.

## Configuration development

Configuration precedence is:

```text
CLI > environment > JSON file > built-in default
```

When adding a configuration field:

1. Add an optional field to `config.FileConfig`.
2. Define the environment-variable behavior in `main.zig` if appropriate.
3. Apply the file/env value before parsing CLI overrides.
4. Validate numeric ranges and incompatible combinations.
5. Add or update tests for strict JSON parsing.
6. Update the configuration example in the project README.
7. Add a `justfile` default only when the recipe exposes that option.

Unknown configuration fields currently fail. Preserve that behavior unless a
forward-compatibility design explicitly replaces it.

## Changing the CLI

`main.zig` performs direct command dispatch without a third-party argument
parser. When adding a command:

1. Place business logic in a focused module instead of growing `main.zig` with
   implementation details.
2. Add the command hierarchy and option parsing in `main.zig`.
3. Use `usageAndExit` for user input errors and reserve propagated errors for
   runtime failures.
4. Add a Just recipe only if the command is a common development or operations
   task.
5. Update the project README and architecture module map as needed.
6. Test both the direct command and the relevant end-to-end flow.

Keep the command hierarchy explicit. Add a shortcut only when it has a durable
operator use case and can be supported as part of the public CLI.

## Changing the heartbeat schema

The schema crosses process and persistence boundaries. Treat it as a protocol,
even while agent and server share one repository.

For a backward-compatible additive field:

1. Update the structs and collector in `heartbeat.zig`.
2. Decide whether the server requires or tolerates the field.
3. Update validation in `server.zig`.
4. Decide whether it needs a queryable column or only belongs in `report_json`.
5. Update storage bindings and list/inspect output when queryable.
6. Update serialization and storage tests.
7. Update the JSON example in `architecture.md`.
8. Cross-build all targets.

For a breaking change, increment `schema_version` and define an explicit server
compatibility policy before merging it. Do not silently reinterpret version 1.

## Changing desired-state or runtime behavior

Desired state crosses the operator, control plane, database, agent, local-state,
and host-runtime boundaries. When changing it:

1. Update `orchestration.zig` and keep validation at both CLI and server trust
   boundaries.
2. Decide how old canonical specifications and `applied.json` records parse.
3. Preserve revision monotonicity and later-wave use of the previous revision.
4. Keep runtime enablement an agent policy; desired state must not expand it.
5. Never introduce shell evaluation for workload or health-check commands.
6. Keep artifact limits active during transfer, before disk usage grows.
7. Add storage-state-machine and pure runtime tests.
8. Run `just orchestration-demo`, then all cross-builds.

Linux process control must verify both PID and `/proc` start-time ticks before
sending a signal. Container images must remain digest-pinned. If a new adapter
needs credentials, mounts, devices, or privileges, define those security and
redaction boundaries before adding fields.

## Changing SQLite storage

The current startup schema records migration versions and uses idempotent
`CREATE TABLE IF NOT EXISTS` statements. This bootstraps new databases, but it
is not yet a complete ordered upgrade runner for destructive column changes.

Before changing existing columns or constraints:

1. Add an ordered migration step and a new `schema_migrations` version.
2. Test upgrading a database created by the previous release.
3. Keep current-node upsert, sampled history, retention, and enrollment audit atomic.
4. Continue binding external values through prepared statements.
5. Decide whether old raw heartbeat JSON remains readable.
6. Verify WAL behavior and graceful server shutdown.

Never solve a schema change by deleting an operator's database automatically.

## Cross-platform rules

Every code change is compiled for all five release targets by `just release`.
Follow these rules:

- Use `builtin.target` for compile-time platform selection.
- Keep OS-specific code small and isolated.
- Do not assume a Unix filesystem layout in shared agent code.
- Do not introduce a runtime dependency without checking static Linux builds
  and the scratch Docker image.
- Keep Windows and macOS code compilable even when integration tests run only
  on Linux.
- Treat hostname environment variables as fallbacks, not a complete inventory
  probe design.

Run `just verify-static` whenever C flags, linking, or dependencies change.

## Testing strategy

Nimbus currently uses three levels of verification:

### Unit tests

`just test` covers schema serialization, validation, identity syntax, retry
backoff, endpoint construction, strict configuration, and in-memory storage.

### Local integration

`just demo` builds Nimbus, starts a temporary server, waits for `/healthz`,
sends a one-shot heartbeat, lists nodes, and terminates the server gracefully.

`just api-check` verifies readiness, authentication rejection, invalid and
oversized heartbeats, accepted heartbeat inspection, and persistence across a
server restart. `just integration` combines this with both end-to-end demos.

`just orchestration-demo` additionally registers a target node, applies a
deployment, reconciles a Linux process, verifies healthy assignment state,
deletes desired state, and verifies that the next pass stops the process.

`just docker-check` performs the equivalent health and shutdown check against
the scratch container image.

### Cross-build verification

`just release` builds all target artifacts. `just verify-static` checks both
Linux artifacts with `file`, and `just checksums` creates the release checksum
manifest.

When a platform-specific runtime behavior is introduced, add native CI or a
real-device test for that behavior; successful cross-compilation alone is not
runtime validation.

## Debugging tips

### Inspect a report without a server

```bash
just inspect
```

### Run an isolated local control plane

```bash
just server 127.0.0.1 18080 /tmp/nimbus-debug.db debug-token
```

In another terminal:

```bash
just agent http://127.0.0.1:18080 edge debug-token
just nodes http://127.0.0.1:18080 debug-token
```

### Run the binary directly

```bash
just run --help
just run agent inspect --id debug-node --role edge
```

### Rebuild from a clean Zig cache

```bash
just clean
just build
```

`just clean` removes only `.zig-cache` and `zig-out`. It does not remove node
identity, SQLite databases, or Docker data.

## Common pitfalls

- **Borrowed JSON strings:** configuration strings must outlive the file read
  buffer; preserve `.alloc_always`.
- **SQLite text lifetime:** a column slice becomes invalid after stepping or
  finalizing its statement.
- **Unbounded loop allocation:** free `init.gpa` allocations during each
  iteration; do not move them casually to the process arena.
- **Reported time vs receipt time:** node liveness must use the server receipt
  time, not the agent clock.
- **One-shot semantics:** `--once` is expected to fail on rejection rather than
  retry forever.
- **HTTP server listener:** clients support HTTPS, but local success does not
  make the embedded HTTP listener secure; use a TLS reverse proxy.
- **Vendored C rebuilds:** changes that invalidate the SQLite object cache make
  clean and Docker builds noticeably slower.
- **Fixed client buffers:** review response-size limits before adding large list
  or inspection payloads.
- **Stale status reports:** rollout failure counts must match the current
  revision; an old report must not roll back a new deployment.
- **SQLite statement text:** copy column text before stepping the same statement,
  and keep the registry mutex held across transactions.
- **PID reuse:** never signal a process record without matching its stored Linux
  start-time ticks.
- **Artifact size:** post-download checks are not sufficient; enforce limits
  while copying or receiving bytes.

## Contribution checklist

Before handing off a change:

- Keep allocations and cleanup visible.
- Add tests beside the changed logic.
- Run `just fmt` and `just check`.
- Run `just pre-commit` for build, protocol, storage, platform, or dependency
  changes.
- Run `just demo` for agent/server/CLI behavior changes.
- Run `just orchestration-demo` for desired-state, status, runtime, or rollout
  changes.
- Run `just docker-check` for container or shutdown changes.
- Update README usage only when users need it.
- Update architecture or development documentation when a boundary, invariant,
  or contributor workflow changes.
- Do not add arbitrary remote command execution or privileged actions without
  a separate security design.
