const std = @import("std");
const Io = std.Io;
const heartbeat = @import("heartbeat.zig");
const identity = @import("identity.zig");
const orchestration = @import("orchestration.zig");
const shutdown = @import("shutdown.zig");
const storage = @import("storage.zig");

const max_heartbeat_bytes = 64 * 1024;
const max_deployment_bytes = 1024 * 1024;
const max_status_bytes = 64 * 1024;
const json_header = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
};

pub const Options = struct {
    bind_address: []const u8,
    port: u16,
    database_path: []const u8,
    stale_after_seconds: u64,
    token: ?[]const u8,
    admin_token: ?[]const u8,
};

pub fn serve(init: std.process.Init, options: Options) !void {
    if (options.stale_after_seconds == 0) return error.InvalidStaleTimeout;
    if (!std.mem.eql(u8, options.database_path, ":memory:")) {
        if (std.fs.path.dirname(options.database_path)) |parent| {
            if (parent.len > 0) try Io.Dir.cwd().createDirPath(init.io, parent);
        }
    }

    var registry = try storage.Registry.open(init.gpa, init.io, options.database_path);
    defer registry.close();

    const address = try Io.net.IpAddress.parse(options.bind_address, options.port);
    var listener = try address.listen(init.io, .{ .reuse_address = true });
    defer listener.deinit(init.io);
    var connections: Io.Group = .init;
    defer connections.cancel(init.io);

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
        connections.concurrent(init.io, handleConnectionTask, .{
            init,
            &registry,
            options,
            stream,
        }) catch |err| {
            stream.close(init.io);
            const message = try std.fmt.allocPrint(init.gpa, "unable to start request task: {t}\n", .{err});
            defer init.gpa.free(message);
            Io.File.stderr().writeStreamingAll(init.io, message) catch {};
        };
    }
    try Io.File.stderr().writeStreamingAll(init.io, "shutdown requested; server stopped\n");
}

fn handleConnectionTask(
    init: std.process.Init,
    registry: *storage.Registry,
    options: Options,
    stream: Io.net.Stream,
) Io.Cancelable!void {
    handleConnection(init, registry, options, stream) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        const message = std.fmt.allocPrint(init.gpa, "request failed: {t}\n", .{err}) catch return;
        defer init.gpa.free(message);
        Io.File.stderr().writeStreamingAll(init.io, message) catch {};
    };
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

    if (!isAuthorized(&request, requiredToken(options, request.head.target))) {
        return respondJson(&request, "{\"error\":\"unauthorized\"}\n", .unauthorized);
    }

    if (request.head.method == .POST and std.mem.eql(u8, request.head.target, "/v1/heartbeat")) {
        return ingestHeartbeat(init, registry, &request);
    }

    if (desiredStateNodeId(request.head.target)) |node_id| {
        if (request.head.method != .GET)
            return respondJson(&request, "{\"error\":\"method_not_allowed\"}\n", .method_not_allowed);
        if (!identity.isValid(node_id))
            return respondJson(&request, "{\"error\":\"invalid_node_id\"}\n", .bad_request);
        const now = Io.Clock.real.now(init.io).toMilliseconds();
        if (try registry.desiredStateForNode(node_id, now)) |response| {
            defer init.gpa.free(response);
            return respondJson(&request, response, .ok);
        }
        return respondJson(&request, "{\"error\":\"node_not_found\"}\n", .not_found);
    }

    if (statusNodeId(request.head.target)) |node_id| {
        if (request.head.method != .POST)
            return respondJson(&request, "{\"error\":\"method_not_allowed\"}\n", .method_not_allowed);
        return ingestWorkloadStatus(init, registry, &request, node_id);
    }

    if (std.mem.eql(u8, request.head.target, "/v1/deployments")) {
        if (request.head.method != .GET)
            return respondJson(&request, "{\"error\":\"method_not_allowed\"}\n", .method_not_allowed);
        const response = try registry.listDeployments();
        defer init.gpa.free(response);
        return respondJson(&request, response, .ok);
    }

    const deployment_prefix = "/v1/deployments/";
    if (std.mem.startsWith(u8, request.head.target, deployment_prefix)) {
        const tail = request.head.target[deployment_prefix.len..];
        if (std.mem.endsWith(u8, tail, "/rollback")) {
            const name = tail[0 .. tail.len - "/rollback".len];
            if (!orchestration.isName(name) or std.mem.indexOfScalar(u8, name, '/') != null)
                return respondJson(&request, "{\"error\":\"invalid_deployment_name\"}\n", .bad_request);
            if (request.head.method != .POST)
                return respondJson(&request, "{\"error\":\"method_not_allowed\"}\n", .method_not_allowed);
            const now = Io.Clock.real.now(init.io).toMilliseconds();
            if (!try registry.rollbackDeployment(name, now))
                return respondJson(&request, "{\"error\":\"no_previous_revision\"}\n", .conflict);
            return respondJson(&request, "{\"rolled_back\":true}\n", .ok);
        }

        if (!orchestration.isName(tail) or std.mem.indexOfScalar(u8, tail, '/') != null)
            return respondJson(&request, "{\"error\":\"invalid_deployment_name\"}\n", .bad_request);
        if (request.head.method == .PUT)
            return ingestDeployment(init, registry, &request, tail);
        if (request.head.method == .GET) {
            if (try registry.inspectDeployment(tail)) |response| {
                defer init.gpa.free(response);
                return respondJson(&request, response, .ok);
            }
            return respondJson(&request, "{\"error\":\"deployment_not_found\"}\n", .not_found);
        }
        if (request.head.method == .DELETE) {
            const now = Io.Clock.real.now(init.io).toMilliseconds();
            if (!try registry.deleteDeployment(tail, now))
                return respondJson(&request, "{\"error\":\"deployment_not_found\"}\n", .not_found);
            return respondJson(&request, "{\"deleted\":true}\n", .ok);
        }
        return respondJson(&request, "{\"error\":\"method_not_allowed\"}\n", .method_not_allowed);
    }

    if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/v1/nodes")) {
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

fn ingestDeployment(
    init: std.process.Init,
    registry: *storage.Registry,
    request: *std.http.Server.Request,
    name: []const u8,
) !void {
    const body = readBodyAlloc(init, request, max_deployment_bytes) catch |err| switch (err) {
        error.StreamTooLong => return respondJson(request, "{\"error\":\"deployment_too_large\"}\n", .payload_too_large),
        else => |other| return other,
    };
    defer init.gpa.free(body);

    var parsed = std.json.parseFromSlice(orchestration.Deployment, init.gpa, body, .{
        .ignore_unknown_fields = false,
    }) catch return respondJson(request, "{\"error\":\"invalid_deployment_json\"}\n", .bad_request);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.name, name))
        return respondJson(request, "{\"error\":\"deployment_name_mismatch\"}\n", .bad_request);
    if (!orchestration.validateDeployment(parsed.value))
        return respondJson(request, "{\"error\":\"invalid_deployment\"}\n", .bad_request);

    const canonical = try std.json.Stringify.valueAlloc(init.gpa, parsed.value, .{});
    defer init.gpa.free(canonical);
    const now = Io.Clock.real.now(init.io).toMilliseconds();
    registry.applyDeployment(parsed.value, canonical, now) catch |err| switch (err) {
        error.RevisionMustIncrease => return respondJson(request, "{\"error\":\"revision_must_increase\"}\n", .conflict),
        else => |other| return other,
    };
    return respondJson(request, "{\"accepted\":true}\n", .accepted);
}

fn ingestWorkloadStatus(
    init: std.process.Init,
    registry: *storage.Registry,
    request: *std.http.Server.Request,
    node_id: []const u8,
) !void {
    if (!identity.isValid(node_id))
        return respondJson(request, "{\"error\":\"invalid_node_id\"}\n", .bad_request);
    const body = readBodyAlloc(init, request, max_status_bytes) catch |err| switch (err) {
        error.StreamTooLong => return respondJson(request, "{\"error\":\"status_too_large\"}\n", .payload_too_large),
        else => |other| return other,
    };
    defer init.gpa.free(body);

    var parsed = std.json.parseFromSlice(orchestration.StatusReport, init.gpa, body, .{
        .ignore_unknown_fields = false,
    }) catch return respondJson(request, "{\"error\":\"invalid_status_json\"}\n", .bad_request);
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.node_id, node_id) or !orchestration.validateStatus(parsed.value))
        return respondJson(request, "{\"error\":\"invalid_status\"}\n", .bad_request);

    const received = Io.Clock.real.now(init.io).toMilliseconds();
    if (!try registry.recordWorkloadStatus(parsed.value, received))
        return respondJson(request, "{\"error\":\"assignment_not_found\"}\n", .not_found);
    return respondJson(request, "{\"accepted\":true}\n", .accepted);
}

fn readBodyAlloc(
    init: std.process.Init,
    request: *std.http.Server.Request,
    maximum: usize,
) ![]u8 {
    var body_buffer: [4096]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buffer);
    return body_reader.allocRemaining(init.gpa, .limited(maximum));
}

fn desiredStateNodeId(target: []const u8) ?[]const u8 {
    return nodeSubresource(target, "/desired-state");
}

fn statusNodeId(target: []const u8) ?[]const u8 {
    return nodeSubresource(target, "/workload-status");
}

fn nodeSubresource(target: []const u8, suffix: []const u8) ?[]const u8 {
    const prefix = "/v1/nodes/";
    if (!std.mem.startsWith(u8, target, prefix) or !std.mem.endsWith(u8, target, suffix)) return null;
    if (target.len <= prefix.len + suffix.len) return null;
    const node_id = target[prefix.len .. target.len - suffix.len];
    if (std.mem.indexOfScalar(u8, node_id, '/') != null) return null;
    return node_id;
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
    if (!(value.schema_version == 1 and
        identity.isValid(value.node_id) and
        value.hostname.len > 0 and value.hostname.len <= 255 and
        value.role.len > 0 and value.role.len <= 64 and
        value.platform.os.len > 0 and value.platform.os.len <= 32 and
        value.platform.arch.len > 0 and value.platform.arch.len <= 32 and
        value.platform.abi.len > 0 and value.platform.abi.len <= 32 and
        value.agent_version.len > 0 and value.agent_version.len <= 64 and
        value.timestamp_unix_ms > 0 and value.labels.len <= 64)) return false;
    for (value.labels, 0..) |label, index| {
        if (!orchestration.isLabelKey(label.key) or !orchestration.isLabelValue(label.value))
            return false;
        for (value.labels[0..index]) |previous| {
            if (std.mem.eql(u8, previous.key, label.key)) return false;
        }
    }
    return true;
}

fn isAuthorized(request: *const std.http.Server.Request, token: ?[]const u8) bool {
    const required = token orelse return true;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "authorization")) continue;
        const prefix = "Bearer ";
        return header.value.len == prefix.len + required.len and
            std.ascii.startsWithIgnoreCase(header.value, prefix) and
            secureTokenEqual(header.value[prefix.len..], required);
    }
    return false;
}

fn secureTokenEqual(provided: []const u8, expected: []const u8) bool {
    if (provided.len != expected.len) return false;
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var provided_hash: [Sha256.digest_length]u8 = undefined;
    var expected_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(provided, &provided_hash, .{});
    Sha256.hash(expected, &expected_hash, .{});
    return std.crypto.timing_safe.eql([Sha256.digest_length]u8, provided_hash, expected_hash);
}

fn requiredToken(options: Options, target: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, target, "/v1/heartbeat") or
        desiredStateNodeId(target) != null or statusNodeId(target) != null)
        return options.token;
    return options.admin_token orelse options.token;
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

test "node orchestration subresources reject nested identifiers" {
    try std.testing.expectEqualStrings(
        "edge-01",
        desiredStateNodeId("/v1/nodes/edge-01/desired-state").?,
    );
    try std.testing.expectEqualStrings(
        "drone-07",
        statusNodeId("/v1/nodes/drone-07/workload-status").?,
    );
    try std.testing.expect(desiredStateNodeId("/v1/nodes/group/edge-01/desired-state") == null);
}

test "operator routes prefer a separate administrative token" {
    const options: Options = .{
        .bind_address = "127.0.0.1",
        .port = 8080,
        .database_path = ":memory:",
        .stale_after_seconds = 90,
        .token = "node-token",
        .admin_token = "admin-token",
    };
    try std.testing.expectEqualStrings("node-token", requiredToken(options, "/v1/heartbeat").?);
    try std.testing.expectEqualStrings(
        "node-token",
        requiredToken(options, "/v1/nodes/edge-01/desired-state").?,
    );
    try std.testing.expectEqualStrings(
        "admin-token",
        requiredToken(options, "/v1/deployments").?,
    );
}
