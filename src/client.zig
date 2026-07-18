const std = @import("std");

pub const SendResult = struct {
    status: std.http.Status,
    response_body: []const u8,
};

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
    var http_client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer http_client.deinit();

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
