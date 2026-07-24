const std = @import("std");

pub const FileConfig = struct {
    server: ?[]const u8 = null,
    role: ?[]const u8 = null,
    labels: ?[]const []const u8 = null,
    node_id_file: ?[]const u8 = null,
    interval_seconds: ?u64 = null,
    jitter_seconds: ?u64 = null,
    retry_initial_seconds: ?u64 = null,
    retry_max_seconds: ?u64 = null,
    orchestration: ?bool = null,
    state_dir: ?[]const u8 = null,
    runtimes: ?[]const u8 = null,
    artifact_public_key: ?[]const u8 = null,
    require_artifact_signatures: ?bool = null,
    max_artifact_bytes: ?u64 = null,
    artifact_cache_bytes: ?u64 = null,
    connectivity_quality_percent: ?u8 = null,
    power_source: ?[]const u8 = null,
    power_budget_milliwatts: ?u64 = null,
    cost_microunits_per_hour: ?u64 = null,
    token: ?[]const u8 = null,
    token_file: ?[]const u8 = null,
    admin_token: ?[]const u8 = null,
    admin_token_file: ?[]const u8 = null,
    node_token_dir: ?[]const u8 = null,
    bind: ?[]const u8 = null,
    port: ?u16 = null,
    database: ?[]const u8 = null,
    stale_after_seconds: ?u64 = null,
    allow_insecure_no_auth: ?bool = null,
};

pub fn load(init: std.process.Init, path: []const u8) !FileConfig {
    var file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(init.io, &read_buffer);
    const bytes = try file_reader.interface.allocRemaining(init.gpa, .limited(256 * 1024));
    defer init.gpa.free(bytes);

    return parse(init.gpa, init.arena.allocator(), bytes);
}

/// Parses a configuration document. JSON remains supported for generated and
/// existing configuration, while YAML is the human-authored default.
pub fn parse(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, bytes: []const u8) !FileConfig {
    const document = std.mem.trim(u8, bytes, " \t\r\n");
    if (document.len == 0) return error.EmptyConfiguration;
    if (document[0] == '{') return parseJson(result_allocator, document);
    return parseYaml(allocator, result_allocator, document);
}

fn parseJson(allocator: std.mem.Allocator, bytes: []const u8) !FileConfig {
    return std.json.parseFromSliceLeaky(FileConfig, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
    });
}

/// Nimbus configuration is deliberately a flat document. This accepts the
/// safe, readable YAML forms needed by that schema: scalar values and a block
/// list for `labels`. YAML tags, anchors, aliases, nested mappings, and
/// multiline scalars are rejected rather than interpreted implicitly.
fn parseYaml(allocator: std.mem.Allocator, result_allocator: std.mem.Allocator, bytes: []const u8) !FileConfig {
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(allocator);
    try json.append(allocator, '{');

    var has_field = false;
    var labels_open = false;
    var has_label = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line_without_cr = std.mem.trimEnd(u8, raw_line, "\r");
        const uncommented = stripYamlComment(line_without_cr);
        const trimmed = std.mem.trim(u8, uncommented, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "...")) continue;

        if (trimmed[0] == '-') {
            if (!labels_open or !hasYamlIndentation(uncommented) or
                (trimmed.len > 1 and trimmed[1] != ' ' and trimmed[1] != '\t'))
                return error.InvalidYaml;
            const value = std.mem.trim(u8, trimmed[1..], " \t");
            if (value.len == 0) return error.InvalidYaml;
            if (has_label) try json.append(allocator, ',');
            try appendYamlString(allocator, &json, value);
            has_label = true;
            continue;
        }

        if (hasYamlIndentation(uncommented)) return error.InvalidYaml;
        if (labels_open) {
            try json.append(allocator, ']');
            labels_open = false;
        }

        const separator = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidYaml;
        const key = std.mem.trim(u8, trimmed[0..separator], " \t");
        const value = std.mem.trim(u8, trimmed[separator + 1 ..], " \t");
        if (!isYamlKey(key)) return error.InvalidYaml;

        if (has_field) try json.append(allocator, ',');
        has_field = true;
        try appendJsonString(allocator, &json, key);
        try json.append(allocator, ':');
        if (value.len == 0) {
            if (!std.mem.eql(u8, key, "labels")) return error.InvalidYaml;
            try json.append(allocator, '[');
            labels_open = true;
            has_label = false;
        } else {
            try appendYamlScalar(allocator, &json, value);
        }
    }

    if (labels_open) try json.append(allocator, ']');
    try json.append(allocator, '}');
    return parseJson(result_allocator, json.items);
}

fn appendYamlScalar(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    if (value[0] == '"' or value[0] == '\'') return appendYamlString(allocator, output, value);
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false") or
        std.mem.eql(u8, value, "null") or isDecimal(value))
    {
        return output.appendSlice(allocator, value);
    }
    // Flow collections are intentionally JSON-only so their types are never
    // inferred using YAML's broader implicit-conversion rules.
    if (value[0] == '[' or value[0] == '{') return output.appendSlice(allocator, value);
    return appendJsonString(allocator, output, value);
}

fn appendYamlString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    if (value[0] == '"') return output.appendSlice(allocator, value);
    if (value[0] != '\'') return appendJsonString(allocator, output, value);
    if (value.len < 2 or value[value.len - 1] != '\'') return error.InvalidYaml;

    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    var index: usize = 1;
    while (index < value.len - 1) : (index += 1) {
        if (value[index] == '\'' and index + 1 < value.len - 1 and value[index + 1] == '\'') {
            try decoded.append(allocator, '\'');
            index += 1;
        } else {
            try decoded.append(allocator, value[index]);
        }
    }
    return appendJsonString(allocator, output, decoded.items);
}

fn appendJsonString(allocator: std.mem.Allocator, output: *std.ArrayList(u8), value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try output.appendSlice(allocator, encoded);
}

fn stripYamlComment(line: []const u8) []const u8 {
    var quoted: ?u8 = null;
    var escaped = false;
    for (line, 0..) |byte, index| {
        if (quoted) |quote| {
            if (quote == '"' and byte == '\\' and !escaped) {
                escaped = true;
                continue;
            }
            if (byte == quote and !escaped) quoted = null;
            escaped = false;
        } else if (byte == '"' or byte == '\'') {
            quoted = byte;
        } else if (byte == '#') {
            return line[0..index];
        }
    }
    return line;
}

fn hasYamlIndentation(line: []const u8) bool {
    return line.len > 0 and (line[0] == ' ' or line[0] == '\t');
}

fn isYamlKey(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

fn isDecimal(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

pub fn envUnsigned(init: std.process.Init, name: []const u8, fallback: u64) !u64 {
    const value = init.environ_map.get(name) orelse return fallback;
    return std.fmt.parseInt(u64, value, 10);
}

pub fn envPort(init: std.process.Init, name: []const u8, fallback: u16) !u16 {
    const value = init.environ_map.get(name) orelse return fallback;
    return std.fmt.parseInt(u16, value, 10);
}

pub fn envBool(init: std.process.Init, name: []const u8, fallback: bool) !bool {
    const value = init.environ_map.get(name) orelse return fallback;
    return parseBool(value);
}

fn parseBool(value: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return error.InvalidBoolean;
}

test "configuration rejects unknown keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnknownField,
        parse(std.testing.allocator, arena.allocator(), "{\"unknown\":true}"),
    );
}

test "JSON configuration remains supported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(
        std.testing.allocator,
        arena.allocator(),
        "{\"server\":\"https://control.example:8080\",\"port\":8080}",
    );
    try std.testing.expectEqualStrings("https://control.example:8080", parsed.server.?);
    try std.testing.expectEqual(@as(u16, 8080), parsed.port.?);
}

test "YAML configuration accepts scalars and labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(std.testing.allocator, arena.allocator(),
        \\# Node configuration is YAML by default.
        \\server: https://control.example:8080
        \\role: edge
        \\labels:
        \\  - site=school-a
        \\  - 'device=teacher''s-desktop'
        \\interval_seconds: 30
        \\orchestration: true
    );
    try std.testing.expectEqualStrings("https://control.example:8080", parsed.server.?);
    try std.testing.expectEqualStrings("edge", parsed.role.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.labels.?.len);
    try std.testing.expectEqualStrings("device=teacher's-desktop", parsed.labels.?[1]);
    try std.testing.expectEqual(@as(u64, 30), parsed.interval_seconds.?);
    try std.testing.expect(parsed.orchestration.?);
}

test "YAML configuration keeps strict unknown field validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.UnknownField,
        parse(std.testing.allocator, arena.allocator(), "unknown: true\n"),
    );
}

test "YAML configuration rejects unsupported nested mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidYaml,
        parse(std.testing.allocator, arena.allocator(), "server:\n  host: control.example\n"),
    );
}

test "boolean environment values are strict" {
    try std.testing.expect(try parseBool("true"));
    try std.testing.expect(!try parseBool("0"));
    try std.testing.expectError(error.InvalidBoolean, parseBool("yes"));
}
