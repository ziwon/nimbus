const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const agent = @import("agent.zig");
const client = @import("client.zig");
const config = @import("config.zig");
const heartbeat = @import("heartbeat.zig");
const identity = @import("identity.zig");
const server = @import("server.zig");

// The initial transport remains plain HTTP. Deployments should terminate TLS at a proxy.
pub const std_options: std.Options = .{ .http_disable_tls = true };

const AgentOptions = struct {
    server_url: []const u8,
    node_id: ?[]const u8,
    node_id_file: []const u8,
    role: []const u8,
    interval_seconds: u64,
    jitter_seconds: u64,
    retry_initial_seconds: u64,
    retry_max_seconds: u64,
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
            try runAgent(init, file_config, args[3..], false);
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
    } else if (std.mem.eql(u8, command, "inspect")) {
        const file_config = try loadConfig(init, args[2..]);
        try inspectAgent(init, file_config, args[2..]);
    } else if (std.mem.eql(u8, command, "send")) {
        const file_config = try loadConfig(init, args[2..]);
        try runAgent(init, file_config, args[2..], true);
    } else if (std.mem.eql(u8, command, "serve")) {
        const file_config = try loadConfig(init, args[2..]);
        try runServer(init, file_config, args[2..]);
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
    const default_token = init.environ_map.get("NIMBUS_TOKEN") orelse file_config.token;
    return .{
        .server_url = default_server,
        .node_id = init.environ_map.get("NIMBUS_NODE_ID"),
        .node_id_file = default_identity_file,
        .role = default_role,
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
        .token = default_token,
    };
}

fn parseAgentOptions(
    init: std.process.Init,
    file_config: config.FileConfig,
    args: []const []const u8,
) !AgentOptions {
    var options = try defaultsForAgent(init, file_config);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--id")) {
            options.node_id = requireValue(init, args, &i, "--id");
        } else if (std.mem.eql(u8, arg, "--identity-file")) {
            options.node_id_file = requireValue(init, args, &i, "--identity-file");
        } else if (std.mem.eql(u8, arg, "--role")) {
            options.role = requireValue(init, args, &i, "--role");
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
        } else if (std.mem.eql(u8, arg, "--token")) {
            options.token = requireValue(init, args, &i, "--token");
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
    return options;
}

fn inspectAgent(init: std.process.Init, file_config: config.FileConfig, args: []const []const u8) !void {
    const options = try parseAgentOptions(init, file_config, args);
    const node_id = options.node_id orelse try identity.loadOrCreate(init, options.node_id_file);
    const value = heartbeat.collect(init, node_id, options.role);
    const payload = try heartbeat.serializeAlloc(init.gpa, value);
    defer init.gpa.free(payload);
    try Io.File.stdout().writeStreamingAll(init.io, payload);
    try Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn runAgent(
    init: std.process.Init,
    file_config: config.FileConfig,
    args: []const []const u8,
    legacy_once: bool,
) !void {
    var options = try parseAgentOptions(init, file_config, args);
    if (legacy_once) options.once = true;
    const node_id = options.node_id orelse try identity.loadOrCreate(init, options.node_id_file);
    try agent.run(init, .{
        .server = options.server_url,
        .node_id = node_id,
        .role = options.role,
        .interval_seconds = options.interval_seconds,
        .jitter_seconds = options.jitter_seconds,
        .retry_initial_seconds = options.retry_initial_seconds,
        .retry_max_seconds = options.retry_max_seconds,
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
    var token = init.environ_map.get("NIMBUS_TOKEN") orelse file_config.token;

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
        } else if (std.mem.eql(u8, arg, "--config")) {
            _ = requireValue(init, args, &i, arg);
        } else {
            usageAndExit(init, "unknown server option");
        }
    }
    try server.serve(init, .{
        .bind_address = bind_address,
        .port = port,
        .database_path = database,
        .stale_after_seconds = stale_after,
        .token = token,
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
    var token = init.environ_map.get("NIMBUS_TOKEN") orelse file_config.token;
    var node_id: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--server")) {
            server_url = requireValue(init, args, &i, arg);
        } else if (std.mem.eql(u8, arg, "--token")) {
            token = requireValue(init, args, &i, arg);
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
        try std.fmt.allocPrint(init.gpa, "{s}/v1/nodes", .{trimmed})
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
        \\  nimbus agent inspect [--id ID] [--identity-file PATH] [--role ROLE]
        \\  nimbus agent run [--server URL] [--interval SEC] [--jitter SEC]
        \\                   [--retry-initial SEC] [--retry-max SEC] [--token TOKEN]
        \\  nimbus server [--bind ADDRESS] [--port PORT] [--database PATH]
        \\                [--stale-after SEC] [--token TOKEN]
        \\  nimbus nodes list [--server URL] [--token TOKEN]
        \\  nimbus nodes inspect NODE_ID [--server URL] [--token TOKEN]
        \\  nimbus version
        \\
        \\All operational commands accept --config PATH. Environment overrides use
        \\NIMBUS_SERVER, NIMBUS_TOKEN, NIMBUS_NODE_ID, NIMBUS_NODE_ID_FILE,
        \\NIMBUS_ROLE, NIMBUS_INTERVAL_SECONDS, NIMBUS_JITTER_SECONDS,
        \\NIMBUS_DATABASE, NIMBUS_BIND, NIMBUS_PORT, and NIMBUS_STALE_AFTER_SECONDS.
        \\
        \\Compatibility aliases: inspect, send, serve.
        \\
    ) catch {};
    std.process.exit(if (message == null) 0 else 2);
}

test {
    _ = agent;
    _ = config;
    _ = heartbeat;
    _ = identity;
    _ = server;
}
