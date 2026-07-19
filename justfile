set shell := ["sh", "-eu", "-c"]

zig := env_var_or_default("ZIG", "zig")
docker_image := env_var_or_default("IMAGE", "nimbus:dev")
control_server := env_var_or_default("NIMBUS_SERVER", "http://127.0.0.1:8080")
control_token := env_var_or_default("NIMBUS_TOKEN", "development-token")
control_admin_token := env_var_or_default("NIMBUS_ADMIN_TOKEN", control_token)
control_bind := env_var_or_default("NIMBUS_BIND", "127.0.0.1")
control_port := env_var_or_default("NIMBUS_PORT", "8080")
control_database := env_var_or_default("NIMBUS_DATABASE", "nimbus.db")
agent_role := env_var_or_default("NIMBUS_ROLE", "edge")
demo_port := env_var_or_default("PORT", "18080")
demo_token := env_var_or_default("TOKEN", "demo-token")
demo_database := env_var_or_default("DATABASE", "")

# List all project tasks.
default: help

# List all project tasks.
help:
    @just --list

# Install the pinned Zig toolchain through Python.
bootstrap:
    python -m pip install ziglang==0.16.0
    @printf '%s\n' 'Use ZIG="python -m ziglang" just <recipe> when zig is not on PATH.'

# Check required and optional development tools.
doctor:
    @printf 'just: '; just --version
    @printf 'zig:  '; {{ zig }} version
    @printf 'git:  '; git --version
    @printf 'shellcheck: '; shellcheck --version | sed -n '1p'
    @printf 'curl: '; curl --version | sed -n '1p'
    @if command -v docker >/dev/null 2>&1; then printf 'docker: '; docker --version; else printf '%s\n' 'docker: optional, not installed'; fi

# Format Zig sources.
fmt:
    {{ zig }} fmt build.zig src

# Verify Zig formatting without changing files.
fmt-check:
    {{ zig }} fmt --check build.zig src
    just --unstable --fmt --check

# Lint compatibility shell wrappers.
lint:
    shellcheck scripts/build-all.sh scripts/demo.sh

# Build the native debug binary.
build:
    {{ zig }} build

# Run all unit tests.
test:
    {{ zig }} build test --summary all

# Print the built Nimbus version.
version: build
    @./zig-out/bin/nimbus --version

# Run formatting, lint, tests, and Git whitespace checks.
check: fmt-check lint test git-check

# Cross-compile all five release targets after tests pass.
release: test
    {{ zig }} build release

# Verify Linux release artifacts are statically linked.
verify-static: release
    @file zig-out/releases/linux-x86_64/nimbus
    @file zig-out/releases/linux-aarch64/nimbus
    @file zig-out/releases/linux-x86_64/nimbus | grep -q 'statically linked'
    @file zig-out/releases/linux-aarch64/nimbus | grep -q 'statically linked'

# List release artifacts and their sizes.
artifacts: release
    @find zig-out/releases -maxdepth 2 -type f -print | sort
    @du -h zig-out/releases/*/nimbus* | sort

# Generate SHA-256 checksums for release artifacts.
checksums: release
    #!/usr/bin/env sh
    set -eu
    cd zig-out/releases
    checksum_file=SHA256SUMS
    : > "$checksum_file"
    find . -mindepth 2 -maxdepth 2 -type f ! -name "$checksum_file" -print | sort | while IFS= read -r artifact; do
      if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$artifact"
      else
        shasum -a 256 "$artifact"
      fi
    done >> "$checksum_file"
    cat "$checksum_file"

# Run native API integration checks.
api-check port="18083" token="api-check-token": build
    #!/usr/bin/env sh
    set -eu
    port={{ quote(port) }}
    token={{ quote(token) }}
    run_dir=$(mktemp -d "${TMPDIR:-/tmp}/nimbus-api-check-XXXXXX")
    database="$run_dir/nimbus.db"
    oversized="$run_dir/oversized.json"
    server_pid=""
    slow_pid=""
    cleanup() {
      if [ -n "$slow_pid" ]; then
        kill "$slow_pid" 2>/dev/null || true
        wait "$slow_pid" 2>/dev/null || true
      fi
      if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
      fi
      find "$run_dir" -depth -delete 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM
    export NIMBUS_TOKEN="$token"
    export NIMBUS_ADMIN_TOKEN="$token"

    ./zig-out/bin/nimbus server --bind 127.0.0.1 --port "$port" --database "$database" &
    server_pid=$!
    ready=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -fsS "http://127.0.0.1:$port/readyz" >/dev/null 2>&1; then ready=true; break; fi
      sleep 0.2
    done
    test "$ready" = true

    python -c 'import socket,sys,time; s=socket.create_connection(("127.0.0.1", int(sys.argv[1]))); s.sendall(b"GET /v1/nodes HTTP/1.1\r\nHost:"); time.sleep(1); s.close()' "$port" &
    slow_pid=$!
    sleep 0.2
    curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null
    wait "$slow_pid"
    slow_pid=""

    test "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/v1/nodes")" = 401
    test "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' "http://127.0.0.1:$port/v1/nodes")" = 401
    test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data '{"schema_version":9}' "http://127.0.0.1:$port/v1/heartbeat")" = 400
    test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data '{"schema_version":1,"node_id":"api-legacy","hostname":"api-legacy","role":"edge","platform":{"os":"linux","arch":"x86_64","abi":"gnu"},"resources":{"cpu_count":2},"timestamp_unix_ms":1000}' "http://127.0.0.1:$port/v1/heartbeat")" = 202
    head -c 70000 /dev/zero | tr '\000' x > "$oversized"
    test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data-binary "@$oversized" "http://127.0.0.1:$port/v1/heartbeat")" = 413

    ./zig-out/bin/nimbus agent run --once --id api-edge --server "http://127.0.0.1:$port"
    test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/nodes/api-edge")" = 200
    curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/nodes/api-edge" | grep -q '"accelerator_inventory"'

    test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data '{"schema_version":3,"node_id":"api-gpu","hostname":"api-gpu","role":"edge","features":["accelerator-requirements-v1"],"platform":{"os":"linux","arch":"x86_64","abi":"gnu"},"resources":{"cpu_count":8},"accelerator_inventory":{"schema_version":1,"status":"complete","accelerators":[{"id":"gpu:nvidia:fixture","kind":"gpu","vendor":"NVIDIA","model":"Fixture","source":"fixture","availability":"available","memory_total_bytes":8589934592,"driver_version":null,"runtimes":[],"capabilities":["fp16"]}],"probes":[{"name":"fixture","status":"ok","devices_found":1,"error_name":null}]},"timestamp_unix_ms":1000}' "http://127.0.0.1:$port/v1/heartbeat")" = 202
    invalid_gpu='{"schema_version":1,"name":"gpu-invalid","revision":1,"runtime":{"kind":"process","command":["/bin/true"]},"resources":{"accelerators":{"count":0,"kind":"gpu"}},"targets":{"node_ids":["api-gpu"]}}'
    test "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data "$invalid_gpu" "http://127.0.0.1:$port/v1/deployments/gpu-invalid")" = 400
    gpu_a='{"schema_version":1,"name":"gpu-a","revision":1,"runtime":{"kind":"process","command":["/bin/true"]},"resources":{"accelerators":{"count":1,"kind":"gpu","vendor":"nvidia","memory_min_bytes":4294967296,"capabilities":["fp16"]}},"targets":{"node_ids":["api-gpu"]}}'
    gpu_b='{"schema_version":1,"name":"gpu-b","revision":1,"runtime":{"kind":"process","command":["/bin/true"]},"resources":{"accelerators":{"count":1,"kind":"gpu","vendor":"nvidia","memory_min_bytes":4294967296,"capabilities":["fp16"]}},"targets":{"node_ids":["api-gpu"]}}'
    test "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data "$gpu_a" "http://127.0.0.1:$port/v1/deployments/gpu-a")" = 202
    test "$(curl -sS -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $token" -H 'Content-Type: application/json' --data "$gpu_b" "http://127.0.0.1:$port/v1/deployments/gpu-b")" = 202
    gpu_desired=$(curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/nodes/api-gpu/desired-state")
    printf '%s' "$gpu_desired" | grep -Fq '"accelerator_assignments":[{"deployment":"gpu-a"'
    printf '%s' "$gpu_desired" | grep -Fq '"name":"gpu-b"'
    ! printf '%s' "$gpu_desired" | grep -Fq '{"deployment":"gpu-b"'
    curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/deployments/gpu-b" | grep -Fq '"reason_code":"accelerator_capacity_exhausted"'
    kill "$server_pid"
    wait "$server_pid"
    server_pid=""

    ./zig-out/bin/nimbus server --bind 127.0.0.1 --port "$port" --database "$database" &
    server_pid=$!
    ready=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -fsS "http://127.0.0.1:$port/readyz" >/dev/null 2>&1; then ready=true; break; fi
      sleep 0.2
    done
    test "$ready" = true
    test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/nodes/api-edge")" = 200
    test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/nodes/api-legacy")" = 200
    curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/nodes/api-gpu/desired-state" | grep -Fq '"accelerator_assignments":[{"deployment":"gpu-a"'
    curl -fsS -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/deployments/gpu-b" | grep -Fq '"reason_code":"accelerator_capacity_exhausted"'

# Run native end-to-end checks.
integration: demo api-check orchestration-demo

# Run the complete local/CI verification pipeline.
ci: check integration release verify-static checksums

# Compatibility aggregate used by scripts/build-all.sh.
build-all: ci artifacts

# Run the Nimbus binary with arbitrary arguments.
run *args: build
    ./zig-out/bin/nimbus {{ args }}

# Start the control plane in the foreground.
server bind=control_bind port=control_port database=control_database token=control_token admin_token=control_admin_token: build
    NIMBUS_TOKEN={{ quote(token) }} NIMBUS_ADMIN_TOKEN={{ quote(admin_token) }} ./zig-out/bin/nimbus server --bind {{ quote(bind) }} --port {{ quote(port) }} --database {{ quote(database) }}

# Start a long-running local agent.
agent server=control_server role=agent_role token=control_token: build
    NIMBUS_TOKEN={{ quote(token) }} ./zig-out/bin/nimbus agent run --server {{ quote(server) }} --role {{ quote(role) }}

# Start an orchestration-enabled agent with an explicit runtime allowlist.
orchestrator server=control_server role=agent_role token=control_token runtimes="process" state_dir=".nimbus-state": build
    NIMBUS_TOKEN={{ quote(token) }} ./zig-out/bin/nimbus agent run --orchestrate --server {{ quote(server) }} --role {{ quote(role) }} --runtimes {{ quote(runtimes) }} --state-dir {{ quote(state_dir) }}

# Print the local node report without sending it.
inspect role=agent_role: build
    ./zig-out/bin/nimbus agent inspect --role {{ quote(role) }}

# List registered nodes.
nodes server=control_server token=control_admin_token: build
    NIMBUS_ADMIN_TOKEN={{ quote(token) }} ./zig-out/bin/nimbus nodes list --server {{ quote(server) }}

# Inspect one registered node.
node node_id server=control_server token=control_admin_token: build
    NIMBUS_ADMIN_TOKEN={{ quote(token) }} ./zig-out/bin/nimbus nodes inspect {{ quote(node_id) }} --server {{ quote(server) }}

# Apply a desired-state deployment document.
deploy file server=control_server token=control_admin_token: build
    NIMBUS_ADMIN_TOKEN={{ quote(token) }} ./zig-out/bin/nimbus deployments apply {{ quote(file) }} --server {{ quote(server) }}

# List desired-state deployments.
deployments server=control_server token=control_admin_token: build
    NIMBUS_ADMIN_TOKEN={{ quote(token) }} ./zig-out/bin/nimbus deployments list --server {{ quote(server) }}

# Inspect rollout and assignment state for one deployment.
deployment name server=control_server token=control_admin_token: build
    NIMBUS_ADMIN_TOKEN={{ quote(token) }} ./zig-out/bin/nimbus deployments inspect {{ quote(name) }} --server {{ quote(server) }}

# Roll a deployment back to its retained previous revision.
rollback name server=control_server token=control_admin_token: build
    NIMBUS_ADMIN_TOKEN={{ quote(token) }} ./zig-out/bin/nimbus deployments rollback {{ quote(name) }} --server {{ quote(server) }}

# Delete desired state; agents stop the workload on their next reconciliation.
undeploy name server=control_server token=control_admin_token: build
    NIMBUS_ADMIN_TOKEN={{ quote(token) }} ./zig-out/bin/nimbus deployments delete {{ quote(name) }} --server {{ quote(server) }}

# Run a disposable end-to-end server/agent/CLI demonstration.
demo port=demo_port token=demo_token database=demo_database: build
    #!/usr/bin/env sh
    set -eu
    port={{ quote(port) }}
    token={{ quote(token) }}
    export NIMBUS_TOKEN="$token"
    export NIMBUS_ADMIN_TOKEN="$token"
    database={{ quote(database) }}
    if [ -z "$database" ]; then
      database="${TMPDIR:-/tmp}/nimbus-demo-$$.db"
    fi

    ./zig-out/bin/nimbus server \
      --bind 127.0.0.1 \
      --port "$port" \
      --database "$database" &
    server_pid=$!
    trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT INT TERM

    ready=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
        ready=true
        break
      fi
      sleep 0.2
    done
    if [ "$ready" != true ]; then
      printf '%s\n' 'Nimbus server did not become ready' >&2
      exit 1
    fi

    ./zig-out/bin/nimbus agent run \
      --once \
      --server "http://127.0.0.1:$port" \
      --id demo-edge \
      --role edge
    ./zig-out/bin/nimbus nodes list \
      --server "http://127.0.0.1:$port"

# Run the Linux process-runtime orchestration flow end to end.
orchestration-demo port="18082" token="orchestration-token": build
    #!/usr/bin/env sh
    set -eu
    port={{ quote(port) }}
    token={{ quote(token) }}
    export NIMBUS_TOKEN="$token"
    export NIMBUS_ADMIN_TOKEN="$token"
    run_dir=$(mktemp -d "${TMPDIR:-/tmp}/nimbus-orchestration-XXXXXX")
    database="$run_dir/nimbus.db"
    state_dir="$run_dir/state"
    server_pid=""
    managed_pid=""
    cleanup() {
      if [ -n "$managed_pid" ] && kill -0 "$managed_pid" 2>/dev/null; then
        kill "$managed_pid" 2>/dev/null || true
      fi
      if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
      fi
      find "$run_dir" -depth -delete 2>/dev/null || true
    }
    trap cleanup EXIT INT TERM

    ./zig-out/bin/nimbus server \
      --bind 127.0.0.1 --port "$port" --database "$database" &
    server_pid=$!
    ready=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
        ready=true
        break
      fi
      sleep 0.2
    done
    test "$ready" = true

    server="http://127.0.0.1:$port"
    ./zig-out/bin/nimbus agent run --once --server "$server" \
      --id demo-edge --role smart-class
    ./zig-out/bin/nimbus deployments apply examples/deployments/process-demo.json \
      --server "$server"
    ./zig-out/bin/nimbus agent run --once --orchestrate --runtimes process \
      --state-dir "$state_dir" --server "$server" \
      --id demo-edge --role smart-class
    ./zig-out/bin/nimbus deployments inspect process-demo \
      --server "$server"

    managed_pid=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$state_dir/applied.json")
    test -n "$managed_pid"
    kill -0 "$managed_pid"
    ./zig-out/bin/nimbus deployments delete process-demo \
      --server "$server"
    ./zig-out/bin/nimbus agent run --once --orchestrate --runtimes process \
      --state-dir "$state_dir" --server "$server" \
      --id demo-edge --role smart-class
    if kill -0 "$managed_pid" 2>/dev/null; then exit 1; fi
    managed_pid=""
    grep -q '"applied":\[\]' "$state_dir/applied.json"

# Build the local Docker image.
docker-build image=docker_image:
    docker build -t {{ quote(image) }} .

# Run the control plane container with persistent local data.
docker-run image=docker_image port="8080" token=control_token: (docker-build image)
    #!/usr/bin/env sh
    set -eu
    mkdir -p data
    NIMBUS_TOKEN={{ quote(token) }} docker run --rm \
      -e NIMBUS_TOKEN \
      -p {{ quote(port) }}:8080 \
      -v "$PWD/data:/data" \
      {{ quote(image) }} \
      server --bind 0.0.0.0 --port 8080 --database /data/nimbus.db

# Build and health-check the Docker image, then stop it gracefully.
docker-check image=docker_image port="18081": (docker-build image)
    #!/usr/bin/env sh
    set -eu
    image={{ quote(image) }}
    port={{ quote(port) }}
    token=docker-check-token
    container="nimbus-just-check-$$"
    if docker run --rm "$image" >/dev/null 2>&1; then
      printf '%s\n' 'unauthenticated non-loopback server unexpectedly started' >&2
      exit 1
    fi
    NIMBUS_TOKEN="$token" docker run -d --rm --name "$container" \
      -e NIMBUS_TOKEN -p "$port:8080" "$image" >/dev/null
    trap 'docker stop -t 2 "$container" >/dev/null 2>&1 || true' EXIT INT TERM
    ready=false
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
        ready=true
        break
      fi
      sleep 0.2
    done
    test "$ready" = true
    curl -fsS "http://127.0.0.1:$port/healthz"
    test "$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/v1/nodes")" = 401
    test "$(curl -sS -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer wrong' "http://127.0.0.1:$port/v1/nodes")" = 401
    test "$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "http://127.0.0.1:$port/v1/nodes")" = 200
    printf '\n'
    docker stop -t 2 "$container" >/dev/null
    trap - EXIT INT TERM

# Remove only generated Zig build output.
clean:
    #!/usr/bin/env sh
    set -eu
    if [ -d .zig-cache ]; then rm -rf -- .zig-cache; fi
    if [ -d zig-out ]; then rm -rf -- zig-out; fi

# Show branch and working-tree state.
git-status:
    @git status --short --branch

# Check and display tracked working-tree changes.
git-diff:
    git diff --check
    git diff --cached --check
    @git diff --stat
    @git diff
    @git diff --cached --stat
    @git diff --cached

# Show recent commits, or a useful message before the first commit.
git-log count="10":
    @if git rev-parse --verify HEAD >/dev/null 2>&1; then git log --oneline -n {{ quote(count) }}; else printf '%s\n' '(no commits yet)'; fi

# Fail when tracked changes contain whitespace errors.
git-check:
    git diff --check
    git diff --cached --check

# Run the checks expected before creating a commit.
pre-commit: check release verify-static
