const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const accelerator = @import("accelerator.zig");
const agent = @import("agent.zig");
const client = @import("client.zig");
const config = @import("config.zig");
const heartbeat = @import("heartbeat.zig");
const identity = @import("identity.zig");
const orchestration = @import("orchestration.zig");
const reconciler = @import("reconciler.zig");
const reservation = @import("reservation.zig");
const runtime = @import("runtime.zig");
const server = @import("server.zig");
const storage = @import("storage.zig");

const AgentOptions = struct {
    server_url: []const u8,
    node_id: ?[]const u8,
    node_id_file: []const u8,
    role: []const u8,
    labels: []const heartbeat.Label,
    interval_seconds: u64,
    jitter_seconds: u64,
    retry_initial_seconds: u64,
    retry_max_seconds: u64,
    orchestration_enabled: bool,
    state_dir: []const u8,
    enabled_runtimes: runtime.Enabled,
    artifact_public_key_hex: ?[]const u8,
    require_artifact_signatures: bool,
    max_artifact_bytes: u64,
    token: ?[]const u8,
    once: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) usageAndExit(init, null);

    const command = args[1];
    if (std.mem.eql(u8, command, "agent")) {
        if (args.len < 3) usageAndExit(init, "agent requires run or inspect");
        const file_config = try loadConfig(init, args[3..]);
        if (std.mem.eql(u8, args[2], "run")) {
            try runAgent(init, file_config, args[3..]);
        } else if (std.mem.eql(u8, args[2], "inspect")) {
            try inspectAgent(init, file_config, args[3..]);
        } else {
            usageAndExit(init, "unknown agent command");
        }
    } else if (std.mem.eql(u8, command, "server")) {
        const file_config = try loadConfig(init, args[2..]);
        try runServer(init, file_config, args[2..]);
    } else if (std.mem.eql(u8, command, "nodes")) {
        if (args.len < 3) usageAndExit(init, "nodes requires list or inspect");
        const file_config = try loadConfig(init, args[3..]);
        try runNodes(init, file_config, args[2], args[3..]);
    } else if (std.mem.eql(u8, command, "deployments")) {
        if (args.len < 3) usageAndExit(init, "deployments requires apply, list, inspect, delete, or rollback");
        const file_config = try loadConfig(init, args[3..]);
        try runDeployments(init, file_config, args[2], args[3..]);
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version")) {
        try Io.File.stdout().writeStreamingAll(init.io, build_options.version ++ "\n");
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        usageAndExit(init, null);
    } else {
        usageAndExit(init, "unknown command");
    }
}

fn loadConfig(init: std.process.Init, args: []const []const u8) !config.FileConfig {
    var path = init.environ_map.get("NIMBUS_CONFIG");
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "--config")) continue;
        i += 1;
        if (i >= args.len) usageAndExit(init, "--config requires a value");
        path = args[i];
    }
    return if (path) |value| config.load(init, value) else .{};
}

fn defaultsForAgent(init: std.process.Init, file_config: config.FileConfig) !AgentOptions {
    const default_server = init.environ_map.get("NIMBUS_SERVER") orelse
        file_config.server orelse "http://127.0.0.1:8080";
    const default_role = init.environ_map.get("NIMBUS_ROLE") orelse file_config.role orelse "edge";
    const default_identity_file = init.environ_map.get("NIMBUS_NODE_ID_FILE") orelse
        file_config.node_id_file orelse ".nimbus-node-id";
    const default_token = try configuredToken(
        init,
        init.environ_map.get("NIMBUS_TOKEN"),
        init.environ_map.get("NIMBUS_TOKEN_FILE"),
        file_config.token,
        file_config.token_file,
    );
    const runtimes_text = init.environ_map.get("NIMBUS_RUNTIMES") orelse
        file_config.runtimes orelse "";
    const labels = try defaultLabels(init, file_config);
    return .{
        .server_url = default_server,
        .node_id = init.environ_map.get("NIMBUS_NODE_ID"),
        .node_id_file = default_identity_file,
        .role = default_role,
        .labels = labels,
        .interval_seconds = try config.envUnsigned(
            init,
            "NIMBUS_INTERVAL_SECONDS",
            file_config.interval_seconds orelse 30,
        ),
        .jitter_seconds = try config.envUnsigned(
            init,
            "NIMBUS_JITTER_SECONDS",
            file_config.jitter_seconds orelse 5,
        ),
        .retry_initial_seconds = try config.envUnsigned(
            init,
            "NIMBUS_RETRY_INITIAL_SECONDS",
            file_config.retry_initial_seconds orelse 1,
        ),
        .retry_max_seconds = try config.envUnsigned(
            init,
            "NIMBUS_RETRY_MAX_SECONDS",
            file_config.retry_max_seconds orelse 30,
        ),
        .orchestration_enabled = try config.envBool(
            init,
            "NIMBUS_ORCHESTRATION",
            file_config.orchestration orelse false,
        ),
        .state_dir = init.environ_map.get("NIMBUS_STATE_DIR") orelse
            file_config.state_dir orelse ".nimbus-state",
        .enabled_runtimes = try runtime.parseEnabled(runtimes_text),
        .artifact_public_key_hex = init.environ_map.get("NIMBUS_ARTIFACT_PUBLIC_KEY") orelse
            file_config.artifact_public_key,
        .require_artifact_signatures = try config.envBool(
            init,
            "NIMBUS_REQUIRE_ARTIFACT_SIGNATURES",
            file_config.require_artifact_signatures orelse false,
        ),
        .max_artifact_bytes = try config.envUnsigned(
            init,
            "NIMBUS_MAX_ARTIFACT_BYTES",
            file_config.max_artifact_bytes orelse 8 * 1024 * 1024 * 1024,
        ),
        .token = default_token,
    };
}

fn parseAgentOptions(
    init: std.process.Init,
    file_config: config.FileConfig,
    args: []const []const u8,
) !AgentOptions {
    var options = try defaultsForAgent(init, file_config);
    var labels: std.ArrayList(heartbeat.Label) = .empty;
    try labels.appendSlice(init.arena.allocator(), options.labels);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--id")) {
            options.node_id = requireValue(init, args, &i, "--id");
        } else if (std.mem.eql(u8, arg, "--identity-file")) {
            options.node_id_file = requireValue(init, args, &i, "--identity-file");
        } else if (std.mem.eql(u8, arg, "--role")) {
            options.role = requireValue(init, args, &i, "--role");
        } else if (std.mem.eql(u8, arg, "--label")) {
            appendLabel(init, &labels, requireValue(init, args, &i, "--label")) catch
                usageAndExit(init, "invalid or duplicate label");
        } else if (std.mem.eql(u8, arg, "--server") or std.mem.eql(u8, arg, "--endpoint")) {
            options.server_url = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--interval")) {
            options.interval_seconds = parseUnsigned(init, requireValue(init, args, &i, arg), arg);
        } else if (std.mem.eql(u8, arg, "--jitter")) {
            options.jitter_seconds = parseUnsigned(init, requireValue(init, args, &i, arg), arg);
        } else if (std.mem.eql(u8, arg, "--retry-initial")) {
            options.retry_initial_seconds = parseUnsigned(init, requireValue(init, args, &i, arg), arg);
        } else if (std.mem.eql(u8, arg, "--retry-max")) {
            options.retry_max_seconds = parseUnsigned(init, requireValue(init, args, &i, arg), arg);
        } else if (std.mem.eql(u8, arg, "--orchestrate")) {
            options.orchestration_enabled = true;
        } else if (std.mem.eql(u8, arg, "--state-dir")) {
            options.state_dir = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--runtimes")) {
            options.enabled_runtimes = runtime.parseEnabled(requireValue(init, args, &i, arg)) catch
                usageAndExit(init, "invalid runtime list");
        } else if (std.mem.eql(u8, arg, "--artifact-public-key")) {
            options.artifact_public_key_hex = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--require-artifact-signatures")) {
            options.require_artifact_signatures = true;
        } else if (std.mem.eql(u8, arg, "--max-artifact-bytes")) {
            options.max_artifact_bytes = parseUnsigned(init, requireValue(init, args, &i, arg), arg);
        } else if (std.mem.eql(u8, arg, "--token")) {
            options.token = requireValue(init, args, &i, "--token");
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            options.token = readTokenFile(init, requireValue(init, args, &i, "--token-file")) catch
                usageAndExit(init, "unable to read token file");
        } else if (std.mem.eql(u8, arg, "--once")) {
            options.once = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            _ = requireValue(init, args, &i, "--config");
        } else {
            usageAndExit(init, "unknown agent option");
        }
    }
    if (options.node_id) |value| {
        if (!identity.isValid(value)) usageAndExit(init, "invalid node ID");
    }
    if (options.role.len == 0 or options.role.len > 64) usageAndExit(init, "invalid role");
    validateAgentTiming(init, options);
    options.labels = labels.items;
    if (options.state_dir.len == 0) usageAndExit(init, "invalid state directory");
    if (options.max_artifact_bytes == 0) usageAndExit(init, "max artifact bytes must be positive");
    if (options.orchestration_enabled and !options.enabled_runtimes.any())
        usageAndExit(init, "--orchestrate requires at least one --runtimes value");
    if (options.require_artifact_signatures and options.artifact_public_key_hex == null)
        usageAndExit(init, "artifact signature verification requires a public key");
    return options;
}

fn inspectAgent(init: std.process.Init, file_config: config.FileConfig, args: []const []const u8) !void {
    const options = try parseAgentOptions(init, file_config, args);
    const node_id = options.node_id orelse try identity.loadOrCreate(init, options.node_id_file);
    var inventory = try accelerator.collectSystem(init.gpa, init.io);
    defer inventory.deinit();
    const value = heartbeat.collect(
        init,
        node_id,
        options.role,
        options.labels,
        &.{heartbeat.feature_accelerator_requirements_v1},
        inventory.report(),
    );
    const payload = try heartbeat.serializeAlloc(init.gpa, value);
    defer init.gpa.free(payload);
    try Io.File.stdout().writeStreamingAll(init.io, payload);
    try Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn runAgent(
    init: std.process.Init,
    file_config: config.FileConfig,
    args: []const []const u8,
) !void {
    const options = try parseAgentOptions(init, file_config, args);
    const node_id = options.node_id orelse try identity.loadOrCreate(init, options.node_id_file);
    try agent.run(init, .{
        .server = options.server_url,
        .node_id = node_id,
        .role = options.role,
        .labels = options.labels,
        .interval_seconds = options.interval_seconds,
        .jitter_seconds = options.jitter_seconds,
        .retry_initial_seconds = options.retry_initial_seconds,
        .retry_max_seconds = options.retry_max_seconds,
        .orchestration_enabled = options.orchestration_enabled,
        .runtime_options = .{
            .enabled = options.enabled_runtimes,
            .state_dir = options.state_dir,
            .artifact_public_key_hex = options.artifact_public_key_hex,
            .require_artifact_signatures = options.require_artifact_signatures,
            .max_artifact_bytes = options.max_artifact_bytes,
        },
        .token = options.token,
        .once = options.once,
    });
}

fn runServer(init: std.process.Init, file_config: config.FileConfig, args: []const []const u8) !void {
    var bind_address = init.environ_map.get("NIMBUS_BIND") orelse file_config.bind orelse "127.0.0.1";
    var port = try config.envPort(init, "NIMBUS_PORT", file_config.port orelse 8080);
    var database = init.environ_map.get("NIMBUS_DATABASE") orelse file_config.database orelse "nimbus.db";
    var stale_after = try config.envUnsigned(
        init,
        "NIMBUS_STALE_AFTER_SECONDS",
        file_config.stale_after_seconds orelse 90,
    );
    var token = try configuredToken(
        init,
        init.environ_map.get("NIMBUS_TOKEN"),
        init.environ_map.get("NIMBUS_TOKEN_FILE"),
        file_config.token,
        file_config.token_file,
    );
    var admin_token = try configuredToken(
        init,
        init.environ_map.get("NIMBUS_ADMIN_TOKEN"),
        init.environ_map.get("NIMBUS_ADMIN_TOKEN_FILE"),
        file_config.admin_token,
        file_config.admin_token_file,
    );
    var allow_insecure_no_auth = try config.envBool(
        init,
        "NIMBUS_ALLOW_INSECURE_NO_AUTH",
        file_config.allow_insecure_no_auth orelse false,
    );

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--bind")) {
            bind_address = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--port")) {
            port = std.fmt.parseInt(u16, requireValue(init, args, &i, arg), 10) catch
                usageAndExit(init, "invalid port");
        } else if (std.mem.eql(u8, arg, "--database")) {
            database = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--stale-after")) {
            stale_after = parseUnsigned(init, requireValue(init, args, &i, arg), arg);
        } else if (std.mem.eql(u8, arg, "--token")) {
            token = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            token = readTokenFile(init, requireValue(init, args, &i, arg)) catch
                usageAndExit(init, "unable to read token file");
        } else if (std.mem.eql(u8, arg, "--admin-token")) {
            admin_token = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--admin-token-file")) {
            admin_token = readTokenFile(init, requireValue(init, args, &i, arg)) catch
                usageAndExit(init, "unable to read admin token file");
        } else if (std.mem.eql(u8, arg, "--allow-insecure-no-auth")) {
            allow_insecure_no_auth = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            _ = requireValue(init, args, &i, arg);
        } else {
            usageAndExit(init, "unknown server option");
        }
    }
    if (stale_after == 0 or stale_after > 30 * 24 * 60 * 60)
        usageAndExit(init, "stale-after must be between 1 second and 30 days");
    try server.serve(init, .{
        .bind_address = bind_address,
        .port = port,
        .database_path = database,
        .stale_after_seconds = stale_after,
        .token = token,
        .admin_token = admin_token,
        .allow_insecure_no_auth = allow_insecure_no_auth,
    });
}

fn runNodes(
    init: std.process.Init,
    file_config: config.FileConfig,
    subcommand: []const u8,
    args: []const []const u8,
) !void {
    var server_url = init.environ_map.get("NIMBUS_SERVER") orelse
        file_config.server orelse "http://127.0.0.1:8080";
    var token = try operatorToken(init, file_config);
    var node_id: ?[]const u8 = null;
    var limit: u16 = 100;
    var after: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--server")) {
            server_url = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--token")) {
            token = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            token = readTokenFile(init, requireValue(init, args, &i, arg)) catch
                usageAndExit(init, "unable to read token file");
        } else if (std.mem.eql(u8, arg, "--limit")) {
            limit = std.fmt.parseInt(u16, requireValue(init, args, &i, arg), 10) catch
                usageAndExit(init, "invalid node list limit");
            if (limit == 0 or limit > 500) usageAndExit(init, "node list limit must be 1..500");
        } else if (std.mem.eql(u8, arg, "--after")) {
            after = requireValue(init, args, &i, arg);
            if (!identity.isValid(after.?)) usageAndExit(init, "invalid node cursor");
        } else if (std.mem.eql(u8, arg, "--config")) {
            _ = requireValue(init, args, &i, arg);
        } else if (!std.mem.startsWith(u8, arg, "--") and node_id == null) {
            node_id = arg;
        } else {
            usageAndExit(init, "unknown nodes option");
        }
    }

    const trimmed = std.mem.trimEnd(u8, server_url, "/");
    const url = if (std.mem.eql(u8, subcommand, "list"))
        if (after) |cursor|
            try std.fmt.allocPrint(
                init.gpa,
                "{s}/v1/nodes?limit={d}&after={s}",
                .{ trimmed, limit, cursor },
            )
        else
            try std.fmt.allocPrint(init.gpa, "{s}/v1/nodes?limit={d}", .{ trimmed, limit })
    else if (std.mem.eql(u8, subcommand, "inspect")) blk: {
        const value = node_id orelse usageAndExit(init, "nodes inspect requires a node ID");
        if (!identity.isValid(value)) usageAndExit(init, "invalid node ID");
        break :blk try std.fmt.allocPrint(init.gpa, "{s}/v1/nodes/{s}", .{ trimmed, value });
    } else usageAndExit(init, "unknown nodes command");
    defer init.gpa.free(url);

    const response_buffer = try init.gpa.alloc(u8, 1024 * 1024);
    defer init.gpa.free(response_buffer);
    const result = try client.getJson(init, url, token, response_buffer);
    if (result.status != .ok) {
        const message = try std.fmt.allocPrint(init.gpa, "HTTP {d}: {s}", .{
            @intFromEnum(result.status),
            result.response_body,
        });
        defer init.gpa.free(message);
        try Io.File.stderr().writeStreamingAll(init.io, message);
        return error.ControlPlaneRequestFailed;
    }
    try Io.File.stdout().writeStreamingAll(init.io, result.response_body);
    if (!std.mem.endsWith(u8, result.response_body, "\n"))
        try Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn runDeployments(
    init: std.process.Init,
    file_config: config.FileConfig,
    subcommand: []const u8,
    args: []const []const u8,
) !void {
    var server_url = init.environ_map.get("NIMBUS_SERVER") orelse
        file_config.server orelse "http://127.0.0.1:8080";
    var token = try operatorToken(init, file_config);
    var operand: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--server")) {
            server_url = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--token")) {
            token = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--token-file")) {
            token = readTokenFile(init, requireValue(init, args, &i, arg)) catch
                usageAndExit(init, "unable to read token file");
        } else if (std.mem.eql(u8, arg, "--config")) {
            _ = requireValue(init, args, &i, arg);
        } else if (!std.mem.startsWith(u8, arg, "--") and operand == null) {
            operand = arg;
        } else {
            usageAndExit(init, "unknown deployments option");
        }
    }

    const trimmed = std.mem.trimEnd(u8, server_url, "/");
    var payload: ?[]u8 = null;
    defer if (payload) |value| init.gpa.free(value);
    var deployment_name: ?[]const u8 = null;

    if (std.mem.eql(u8, subcommand, "apply")) {
        const path = operand orelse usageAndExit(init, "deployments apply requires a JSON file");
        payload = try readFileAlloc(init, path, 1024 * 1024);
        var parsed = std.json.parseFromSlice(orchestration.Deployment, init.gpa, payload.?, .{
            .ignore_unknown_fields = false,
        }) catch usageAndExit(init, "invalid deployment JSON");
        defer parsed.deinit();
        if (!orchestration.validateDeployment(parsed.value))
            usageAndExit(init, "invalid deployment specification");
        deployment_name = try init.arena.allocator().dupe(u8, parsed.value.name);
    } else if (std.mem.eql(u8, subcommand, "list")) {
        if (operand != null) usageAndExit(init, "deployments list does not accept a name");
    } else if (std.mem.eql(u8, subcommand, "inspect") or
        std.mem.eql(u8, subcommand, "delete") or
        std.mem.eql(u8, subcommand, "rollback"))
    {
        deployment_name = operand orelse usageAndExit(init, "deployment name required");
        if (!orchestration.isName(deployment_name.?)) usageAndExit(init, "invalid deployment name");
    } else {
        usageAndExit(init, "unknown deployments command");
    }

    const url = if (std.mem.eql(u8, subcommand, "list"))
        try std.fmt.allocPrint(init.gpa, "{s}/v1/deployments", .{trimmed})
    else if (std.mem.eql(u8, subcommand, "rollback"))
        try std.fmt.allocPrint(
            init.gpa,
            "{s}/v1/deployments/{s}/rollback",
            .{ trimmed, deployment_name.? },
        )
    else
        try std.fmt.allocPrint(init.gpa, "{s}/v1/deployments/{s}", .{ trimmed, deployment_name.? });
    defer init.gpa.free(url);

    const response_buffer = try init.gpa.alloc(u8, 1024 * 1024);
    defer init.gpa.free(response_buffer);
    const result = if (std.mem.eql(u8, subcommand, "apply"))
        try client.putJson(init, url, payload.?, token, response_buffer)
    else if (std.mem.eql(u8, subcommand, "delete"))
        try client.deleteJson(init, url, token, response_buffer)
    else if (std.mem.eql(u8, subcommand, "rollback"))
        try client.postJson(init, url, "{}", token, response_buffer)
    else
        try client.getJson(init, url, token, response_buffer);
    try writeControlResponse(init, result);
}

fn readFileAlloc(init: std.process.Init, path: []const u8, maximum: usize) ![]u8 {
    var file = try Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(init.io, &buffer);
    return reader.interface.allocRemaining(init.gpa, .limited(maximum));
}

fn readTokenFile(init: std.process.Init, path: []const u8) ![]const u8 {
    const bytes = try readFileAlloc(init, path, 64 * 1024);
    defer init.gpa.free(bytes);
    const token = std.mem.trim(u8, bytes, " \t\r\n");
    if (token.len == 0 or token.len > 4096) return error.InvalidTokenFile;
    return init.arena.allocator().dupe(u8, token);
}

fn configuredToken(
    init: std.process.Init,
    environment_token: ?[]const u8,
    environment_file: ?[]const u8,
    config_token: ?[]const u8,
    config_file: ?[]const u8,
) !?[]const u8 {
    if (environment_token) |value| return value;
    if (environment_file) |path| return try readTokenFile(init, path);
    if (config_token) |value| return value;
    if (config_file) |path| return try readTokenFile(init, path);
    return null;
}

fn operatorToken(init: std.process.Init, file_config: config.FileConfig) !?[]const u8 {
    if (init.environ_map.get("NIMBUS_ADMIN_TOKEN")) |value| return value;
    if (init.environ_map.get("NIMBUS_ADMIN_TOKEN_FILE")) |path| return try readTokenFile(init, path);
    if (init.environ_map.get("NIMBUS_TOKEN")) |value| return value;
    if (init.environ_map.get("NIMBUS_TOKEN_FILE")) |path| return try readTokenFile(init, path);
    if (file_config.admin_token) |value| return value;
    if (file_config.admin_token_file) |path| return try readTokenFile(init, path);
    if (file_config.token) |value| return value;
    if (file_config.token_file) |path| return try readTokenFile(init, path);
    return null;
}

fn validateAgentTiming(init: std.process.Init, options: AgentOptions) void {
    if (options.interval_seconds == 0 or options.interval_seconds > 24 * 60 * 60)
        usageAndExit(init, "interval must be between 1 second and 24 hours");
    if (options.jitter_seconds > 60 * 60)
        usageAndExit(init, "jitter must be at most 1 hour");
    if (options.jitter_seconds > options.interval_seconds)
        usageAndExit(init, "jitter must not exceed interval");
    if (options.retry_initial_seconds == 0 or options.retry_initial_seconds > 10 * 60)
        usageAndExit(init, "retry-initial must be between 1 second and 10 minutes");
    if (options.retry_max_seconds == 0 or options.retry_max_seconds > 60 * 60)
        usageAndExit(init, "retry-max must be between 1 second and 1 hour");
    if (options.retry_initial_seconds > options.retry_max_seconds)
        usageAndExit(init, "retry-initial must not exceed retry-max");
}

fn writeControlResponse(init: std.process.Init, result: client.SendResult) !void {
    const status_code = @intFromEnum(result.status);
    if (status_code < 200 or status_code >= 300) {
        const message = try std.fmt.allocPrint(init.gpa, "HTTP {d}: {s}", .{
            status_code,
            result.response_body,
        });
        defer init.gpa.free(message);
        try Io.File.stderr().writeStreamingAll(init.io, message);
        return error.ControlPlaneRequestFailed;
    }
    try Io.File.stdout().writeStreamingAll(init.io, result.response_body);
    if (!std.mem.endsWith(u8, result.response_body, "\n"))
        try Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn requireValue(
    init: std.process.Init,
    args: []const []const u8,
    index: *usize,
    option: []const u8,
) []const u8 {
    index.* += 1;
    if (index.* >= args.len) {
        const message = std.fmt.allocPrint(init.gpa, "{s} requires a value", .{option}) catch
            usageAndExit(init, "option requires a value");
        defer init.gpa.free(message);
        usageAndExit(init, message);
    }
    return args[index.*];
}

fn defaultLabels(init: std.process.Init, file_config: config.FileConfig) ![]const heartbeat.Label {
    var labels: std.ArrayList(heartbeat.Label) = .empty;
    if (init.environ_map.get("NIMBUS_LABELS")) |encoded| {
        var iterator = std.mem.splitScalar(u8, encoded, ',');
        while (iterator.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " \t");
            if (trimmed.len > 0) try appendLabel(init, &labels, trimmed);
        }
    } else if (file_config.labels) |configured| {
        for (configured) |item| try appendLabel(init, &labels, item);
    }
    return labels.items;
}

fn appendLabel(
    init: std.process.Init,
    labels: *std.ArrayList(heartbeat.Label),
    encoded: []const u8,
) !void {
    const separator = std.mem.indexOfScalar(u8, encoded, '=') orelse return error.InvalidLabel;
    const key = encoded[0..separator];
    const value = encoded[separator + 1 ..];
    if (!orchestration.isLabelKey(key) or !orchestration.isLabelValue(value))
        return error.InvalidLabel;
    for (labels.items) |label| {
        if (std.mem.eql(u8, label.key, key)) return error.DuplicateLabel;
    }
    try labels.append(init.arena.allocator(), .{ .key = key, .value = value });
}

fn parseUnsigned(init: std.process.Init, value: []const u8, option: []const u8) u64 {
    return std.fmt.parseInt(u64, value, 10) catch {
        const message = std.fmt.allocPrint(init.gpa, "invalid value for {s}", .{option}) catch
            usageAndExit(init, "invalid numeric option");
        defer init.gpa.free(message);
        usageAndExit(init, message);
    };
}

fn usageAndExit(init: std.process.Init, message: ?[]const u8) noreturn {
    if (message) |text| {
        Io.File.stderr().writeStreamingAll(init.io, text) catch {};
        Io.File.stderr().writeStreamingAll(init.io, "\n\n") catch {};
    }
    Io.File.stderr().writeStreamingAll(init.io,
        \\nimbus - lightweight heterogeneous fleet management
        \\
        \\Usage:
        \\  nimbus agent inspect [--id ID] [--identity-file PATH] [--role ROLE] [--label KEY=VALUE]
        \\  nimbus agent run [--server URL] [--interval SEC] [--jitter SEC]
        \\                   [--retry-initial SEC] [--retry-max SEC] [--once]
        \\                   [--token TOKEN | --token-file PATH]
        \\                   [--label KEY=VALUE] [--orchestrate] [--runtimes CSV]
        \\                   [--state-dir PATH]
        \\                   [--artifact-public-key HEX] [--require-artifact-signatures]
        \\  nimbus server [--bind ADDRESS] [--port PORT] [--database PATH]
        \\                [--stale-after SEC] [--token TOKEN | --token-file PATH]
        \\                [--admin-token TOKEN | --admin-token-file PATH]
        \\                [--allow-insecure-no-auth]
        \\  nimbus nodes list [--server URL] [--limit N] [--after NODE_ID]
        \\                    [--token TOKEN | --token-file PATH]
        \\  nimbus nodes inspect NODE_ID [--server URL] [--token TOKEN | --token-file PATH]
        \\  nimbus deployments apply FILE [--server URL] [--token TOKEN | --token-file PATH]
        \\  nimbus deployments list [--server URL] [--token TOKEN | --token-file PATH]
        \\  nimbus deployments inspect NAME [--server URL] [--token TOKEN | --token-file PATH]
        \\  nimbus deployments delete NAME [--server URL] [--token TOKEN | --token-file PATH]
        \\  nimbus deployments rollback NAME [--server URL] [--token TOKEN | --token-file PATH]
        \\  nimbus version
        \\
        \\All operational commands accept --config PATH. Environment overrides use
        \\NIMBUS_SERVER, NIMBUS_TOKEN, NIMBUS_TOKEN_FILE, NIMBUS_NODE_ID,
        \\NIMBUS_NODE_ID_FILE,
        \\NIMBUS_ROLE, NIMBUS_LABELS, NIMBUS_INTERVAL_SECONDS, NIMBUS_JITTER_SECONDS,
        \\NIMBUS_DATABASE, NIMBUS_BIND, NIMBUS_PORT, NIMBUS_STALE_AFTER_SECONDS,
        \\NIMBUS_ORCHESTRATION, NIMBUS_RUNTIMES, NIMBUS_STATE_DIR,
        \\NIMBUS_ARTIFACT_PUBLIC_KEY, NIMBUS_REQUIRE_ARTIFACT_SIGNATURES,
        \\NIMBUS_MAX_ARTIFACT_BYTES, NIMBUS_ADMIN_TOKEN, NIMBUS_ADMIN_TOKEN_FILE,
        \\and NIMBUS_ALLOW_INSECURE_NO_AUTH.
        \\
    ) catch {};
    std.process.exit(if (message == null) 0 else 2);
}

test {
    _ = accelerator;
    _ = agent;
    _ = config;
    _ = heartbeat;
    _ = identity;
    _ = orchestration;
    _ = reconciler;
    _ = reservation;
    _ = runtime;
    _ = server;
    _ = storage;
}
