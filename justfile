set shell := ["sh", "-eu", "-c"]

zig := env_var_or_default("ZIG", "zig")
docker_image := env_var_or_default("IMAGE", "nimbus:dev")
control_server := env_var_or_default("NIMBUS_SERVER", "http://127.0.0.1:8080")
control_token := env_var_or_default("NIMBUS_TOKEN", "development-token")
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

# Run the complete local/CI verification pipeline.
ci: check release verify-static checksums

# Compatibility aggregate used by scripts/build-all.sh.
build-all: ci artifacts

# Run the Nimbus binary with arbitrary arguments.
run *args: build
    ./zig-out/bin/nimbus {{ args }}

# Start the control plane in the foreground.
server bind=control_bind port=control_port database=control_database token=control_token: build
    ./zig-out/bin/nimbus server --bind {{ quote(bind) }} --port {{ quote(port) }} --database {{ quote(database) }} --token {{ quote(token) }}

# Start a long-running local agent.
agent server=control_server role=agent_role token=control_token: build
    ./zig-out/bin/nimbus agent run --server {{ quote(server) }} --role {{ quote(role) }} --token {{ quote(token) }}

# Print the local node report without sending it.
inspect role=agent_role: build
    ./zig-out/bin/nimbus agent inspect --role {{ quote(role) }}

# List registered nodes.
nodes server=control_server token=control_token: build
    ./zig-out/bin/nimbus nodes list --server {{ quote(server) }} --token {{ quote(token) }}

# Inspect one registered node.
node node_id server=control_server token=control_token: build
    ./zig-out/bin/nimbus nodes inspect {{ quote(node_id) }} --server {{ quote(server) }} --token {{ quote(token) }}

# Run a disposable end-to-end server/agent/CLI demonstration.
demo port=demo_port token=demo_token database=demo_database: build
    #!/usr/bin/env sh
    set -eu
    port={{ quote(port) }}
    token={{ quote(token) }}
    database={{ quote(database) }}
    if [ -z "$database" ]; then
      database="${TMPDIR:-/tmp}/nimbus-demo-$$.db"
    fi

    ./zig-out/bin/nimbus server \
      --bind 127.0.0.1 \
      --port "$port" \
      --database "$database" \
      --token "$token" &
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
      --role edge \
      --token "$token"
    ./zig-out/bin/nimbus nodes list \
      --server "http://127.0.0.1:$port" \
      --token "$token"

# Build the local Docker image.
docker-build image=docker_image:
    docker build -t {{ quote(image) }} .

# Run the control plane container with persistent local data.
docker-run image=docker_image port="8080" token=control_token: (docker-build image)
    mkdir -p data
    docker run --rm \
      -p {{ quote(port) }}:8080 \
      -v "$PWD/data:/data" \
      {{ quote(image) }} \
      server --bind 0.0.0.0 --port 8080 --database /data/nimbus.db --token {{ quote(token) }}

# Build and health-check the Docker image, then stop it gracefully.
docker-check image=docker_image port="18081": (docker-build image)
    #!/usr/bin/env sh
    set -eu
    image={{ quote(image) }}
    port={{ quote(port) }}
    container="nimbus-just-check-$$"
    docker run -d --rm --name "$container" -p "$port:8080" "$image" >/dev/null
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
