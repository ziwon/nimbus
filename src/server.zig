const std = @import("std");
const Io = std.Io;
const heartbeat = @import("heartbeat.zig");
const identity = @import("identity.zig");
const shutdown = @import("shutdown.zig");
const storage = @import("storage.zig");

const max_heartbeat_bytes = 64 * 1024;
const json_header = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
};

pub const Options = struct {
    bind_address: []const u8,
    port: u16,
    database_path: []const u8,
    stale_after_seconds: u64,
    token: ?[]const u8,
};

pub fn serve(init: std.process.Init, options: Options) !void {
    if (options.stale_after_seconds == 0) return error.InvalidStaleTimeout;
    if (!std.mem.eql(u8, options.database_path, ":memory:")) {
        if (std.fs.path.dirname(options.database_path)) |parent| {
            if (parent.len > 0) try Io.Dir.cwd().createDirPath(init.io, parent);
        }
    }

    var registry = try storage.Registry.open(init.gpa, options.database_path);
    defer registry.close();

    const address = try Io.net.IpAddress.parse(options.bind_address, options.port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);

    shutdown.install();
    var shutdown_monitor = try init.io.concurrent(shutdownListener, .{ init.io, &listener });
    defer _ = shutdown_monitor.cancel(init.io) catch {};

    const notice = try std.fmt.allocPrint(
        init.gpa,
        "nimbus server listening on http://{s}:{d} (database: {s})\n",
        .{ options.bind_address, listener.socket.address.getPort(), options.database_path },
    );
    defer init.gpa.free(notice);
    try Io.File.stderr().writeStreamingAll(init.io, notice);

    while (!shutdown.isRequested()) {
        const stream = listener.accept(init.io) catch |err| switch (err) {
            error.SocketNotListening => if (shutdown.isRequested()) break else return err,
            error.Canceled => if (shutdown.isRequested()) break else return err,
            else => return err,
        };
        handleConnection(init, &registry, options, stream) catch |err| {
            const message = try std.fmt.allocPrint(init.gpa, "request failed: {t}\n", .{err});
            defer init.gpa.free(message);
            Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        };
    }
    try Io.File.stderr().writeStreamingAll(init.io, "shutdown requested; server stopped\n");
}

fn shutdownListener(io: Io, listener: *Io.net.Server) Io.Cancelable!void {
    while (!shutdown.isRequested()) {
        const duration: Io.Clock.Duration = .{
            .clock = .boot,
            .raw = .fromMilliseconds(100),
        };
        try duration.sleep(io);
    }
    const stream: Io.net.Stream = .{ .socket = listener.socket };
    stream.shutdown(io, .both) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}

fn handleConnection(
    init: std.process.Init,
    registry: *storage.Registry,
    options: Options,
    stream: Io.net.Stream,
) !void {
    defer stream.close(init.io);

    var recv_buffer: [8192]u8 = undefined;
    var send_buffer: [8192]u8 = undefined;
    var conn_reader = stream.reader(init.io, &recv_buffer);
    var conn_writer = stream.writer(init.io, &send_buffer);
    var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);
    var request = try http_server.receiveHead();

    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/healthz")) {
        return respondJson(&request, "{\"status\":\"ok\"}\n", .ok);
    }

    if (!isAuthorized(&request, options.token)) {
        return respondJson(&request, "{\"error\":\"unauthorized\"}\n", .unauthorized);
    }

    if (request.head.method == .POST and std.mem.eql(u8, request.head.target, "/v1/heartbeat")) {
        return ingestHeartbeat(init, registry, &request);
    }

    if (request.head.method == .GET and
        (std.mem.eql(u8, request.head.target, "/v1/nodes") or
            std.mem.eql(u8, request.head.target, "/v1/agents")))
    {
        const now = Io.Clock.real.now(init.io).toMilliseconds();
        const response = try registry.listNodes(now, staleMillis(options.stale_after_seconds));
        defer init.gpa.free(response);
        return respondJson(&request, response, .ok);
    }

    const inspect_prefix = "/v1/nodes/";
    if (request.head.method == .GET and std.mem.startsWith(u8, request.head.target, inspect_prefix)) {
        const node_id = request.head.target[inspect_prefix.len..];
        if (!identity.isValid(node_id))
            return respondJson(&request, "{\"error\":\"invalid_node_id\"}\n", .bad_request);
        const now = Io.Clock.real.now(init.io).toMilliseconds();
        if (try registry.inspectNode(node_id, now, staleMillis(options.stale_after_seconds))) |response| {
            defer init.gpa.free(response);
            return respondJson(&request, response, .ok);
        }
        return respondJson(&request, "{\"error\":\"node_not_found\"}\n", .not_found);
    }

    return respondJson(&request, "{\"error\":\"not_found\"}\n", .not_found);
}

fn ingestHeartbeat(
    init: std.process.Init,
    registry: *storage.Registry,
    request: *std.http.Server.Request,
) !void {
    var body_buffer: [4096]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buffer);
    const body = body_reader.allocRemaining(init.gpa, .limited(max_heartbeat_bytes)) catch |err| switch (err) {
        error.StreamTooLong => return respondJson(request, "{\"error\":\"heartbeat_too_large\"}\n", .payload_too_large),
        else => |other| return other,
    };
    defer init.gpa.free(body);

    var parsed = std.json.parseFromSlice(heartbeat.Heartbeat, init.gpa, body, .{}) catch
        return respondJson(request, "{\"error\":\"invalid_heartbeat_json\"}\n", .bad_request);
    defer parsed.deinit();
    if (!validHeartbeat(parsed.value))
        return respondJson(request, "{\"error\":\"invalid_heartbeat\"}\n", .bad_request);

    const received = Io.Clock.real.now(init.io).toMilliseconds();
    try registry.recordHeartbeat(parsed.value, body, received);
    return respondJson(request, "{\"accepted\":true}\n", .accepted);
}

fn validHeartbeat(value: heartbeat.Heartbeat) bool {
    return value.schema_version == 1 and
        identity.isValid(value.node_id) and
        value.hostname.len > 0 and value.hostname.len <= 255 and
        value.role.len > 0 and value.role.len <= 64 and
        value.platform.os.len > 0 and value.platform.os.len <= 32 and
        value.platform.arch.len > 0 and value.platform.arch.len <= 32 and
        value.platform.abi.len > 0 and value.platform.abi.len <= 32 and
        value.agent_version.len > 0 and value.agent_version.len <= 64 and
        value.timestamp_unix_ms > 0;
}

fn isAuthorized(request: *const std.http.Server.Request, token: ?[]const u8) bool {
    const required = token orelse return true;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
        const prefix = "Bearer ";
        return header.value.len == prefix.len + required.len and
            std.ascii.startsWithIgnoreCase(header.value, prefix) and
            std.mem.eql(u8, header.value[prefix.len..], required);
    }
    return false;
}

fn staleMillis(seconds: u64) i64 {
    return @intCast(@min(seconds, @as(u64, @intCast(std.math.maxInt(i64) / 1000))) * 1000);
}

fn respondJson(request: *std.http.Server.Request, body: []const u8, status: std.http.Status) !void {
    return request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &json_header,
    });
}

test "heartbeat validation rejects unsupported schemas" {
    const value: heartbeat.Heartbeat = .{
        .schema_version = 2,
        .node_id = "edge-01",
        .hostname = "edge-01",
        .role = "edge",
        .platform = .{ .os = "linux", .arch = "aarch64", .abi = "musl" },
        .resources = .{ .cpu_count = 4 },
        .timestamp_unix_ms = 1000,
    };
    try std.testing.expect(!validHeartbeat(value));
}
