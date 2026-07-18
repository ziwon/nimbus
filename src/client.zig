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
    var client: std.http.Client = .{
        .allocator = init.gpa,
        .io = init.io,
    };
    defer client.deinit();

    var response_writer: std.Io.Writer = .fixed(response_buffer);
    var headers: [3]std.http.Header = undefined;
    headers[0] = .{ .name = "content-type", .value = "application/json" };
    headers[1] = .{ .name = "accept", .value = "application/json" };
    var header_count: usize = 2;
    var authorization_buffer: [1024]u8 = undefined;
    if (token) |value| {
        const authorization = try std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{value});
        headers[2] = .{ .name = "authorization", .value = authorization };
        header_count = 3;
    }

    const result = try client.fetch(.{
        .location = .{ .url = endpoint },
        .method = .POST,
        .payload = payload,
        .response_writer = &response_writer,
        .keep_alive = false,
        .extra_headers = headers[0..header_count],
    });

    return .{
        .status = result.status,
        .response_body = response_writer.buffered(),
    };
}

pub fn getJson(
    init: std.process.Init,
    url: []const u8,
    token: ?[]const u8,
    response_buffer: []u8,
) !SendResult {
    var http_client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer http_client.deinit();

    var headers: [2]std.http.Header = undefined;
    headers[0] = .{ .name = "accept", .value = "application/json" };
    var header_count: usize = 1;
    var authorization_buffer: [1024]u8 = undefined;
    if (token) |value| {
        const authorization = try std.fmt.bufPrint(&authorization_buffer, "Bearer {s}", .{value});
        headers[1] = .{ .name = "authorization", .value = authorization };
        header_count = 2;
    }

    var response_writer: std.Io.Writer = .fixed(response_buffer);
    const result = try http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_writer,
        .keep_alive = false,
        .extra_headers = headers[0..header_count],
    });
    return .{ .status = result.status, .response_body = response_writer.buffered() };
}
