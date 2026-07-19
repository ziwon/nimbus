const std = @import("std");

pub const SendResult = struct {
    status: std.http.Status,
    response_body: []const u8,
};

const request_timeout_seconds = 15;

pub fn sendHeartbeat(
    init: std.process.Init,
    endpoint: []const u8,
    payload: []const u8,
    token: ?[]const u8,
    response_buffer: []u8,
) !SendResult {
    return requestJson(init, endpoint, .POST, payload, token, response_buffer);
}

pub fn getJson(
    init: std.process.Init,
    url: []const u8,
    token: ?[]const u8,
    response_buffer: []u8,
) !SendResult {
    return requestJson(init, url, .GET, null, token, response_buffer);
}

pub fn putJson(
    init: std.process.Init,
    url: []const u8,
    payload: []const u8,
    token: ?[]const u8,
    response_buffer: []u8,
) !SendResult {
    return requestJson(init, url, .PUT, payload, token, response_buffer);
}

pub fn postJson(
    init: std.process.Init,
    url: []const u8,
    payload: []const u8,
    token: ?[]const u8,
    response_buffer: []u8,
) !SendResult {
    return requestJson(init, url, .POST, payload, token, response_buffer);
}

pub fn deleteJson(
    init: std.process.Init,
    url: []const u8,
    token: ?[]const u8,
    response_buffer: []u8,
) !SendResult {
    return requestJson(init, url, .DELETE, null, token, response_buffer);
}

pub fn requestJson(
    init: std.process.Init,
    url: []const u8,
    method: std.http.Method,
    payload: ?[]const u8,
    token: ?[]const u8,
    response_buffer: []u8,
) !SendResult {
    const SelectResult = union(enum) {
        request: anyerror!SendResult,
        timeout: std.Io.Cancelable!void,
    };
    var results: [2]SelectResult = undefined;
    var select: std.Io.Select(SelectResult) = .init(init.io, &results);
    try select.concurrent(.request, performRequest, .{
        init,
        url,
        method,
        payload,
        token,
        response_buffer,
    });
    select.async(.timeout, requestDeadline, .{init.io});

    switch (try select.await()) {
        .request => |result| {
            select.cancelDiscard();
            return result;
        },
        .timeout => |result| {
            try result;
            select.cancelDiscard();
            return error.RequestTimeout;
        },
    }
}

fn requestDeadline(io: std.Io) std.Io.Cancelable!void {
    const duration: std.Io.Clock.Duration = .{
        .clock = .boot,
        .raw = .fromSeconds(request_timeout_seconds),
    };
    return duration.sleep(io);
}

fn performRequest(
    init: std.process.Init,
    url: []const u8,
    method: std.http.Method,
    payload: ?[]const u8,
    token: ?[]const u8,
    response_buffer: []u8,
) anyerror!SendResult {
    var http_client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer http_client.deinit();
    if (init.environ_map.get("NIMBUS_CA_FILE")) |path|
        try configureCertificateAuthorities(init, &http_client, path);

    var headers: [3]std.http.Header = undefined;
    headers[0] = .{ .name = "accept", .value = "application/json" };
    var header_count: usize = 1;
    if (payload != null) {
        headers[header_count] = .{ .name = "content-type", .value = "application/json" };
        header_count += 1;
    }
    var authorization_buffer: [1024]u8 = undefined;
    if (token) |value| {
        const authorization = try std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{value});
        headers[header_count] = .{ .name = "authorization", .value = authorization };
        header_count += 1;
    }

    var response_writer: std.Io.Writer = .fixed(response_buffer);
    const result = try http_client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &response_writer,
        .keep_alive = false,
        .extra_headers = headers[0..header_count],
    });
    return .{ .status = result.status, .response_body = response_writer.buffered() };
}

fn configureCertificateAuthorities(
    init: std.process.Init,
    http_client: *std.http.Client,
    path: []const u8,
) !void {
    if (path.len == 0) return error.InvalidCertificateAuthorityPath;
    const now = std.Io.Clock.real.now(init.io);
    var bundle: std.crypto.Certificate.Bundle = .empty;
    errdefer bundle.deinit(init.gpa);
    try bundle.rescan(init.gpa, init.io, now);
    if (std.fs.path.isAbsolute(path)) {
        try bundle.addCertsFromFilePathAbsolute(init.gpa, init.io, now, path);
    } else {
        try bundle.addCertsFromFilePath(init.gpa, init.io, now, std.Io.Dir.cwd(), path);
    }
    http_client.ca_bundle = bundle;
    http_client.now = now;
}
