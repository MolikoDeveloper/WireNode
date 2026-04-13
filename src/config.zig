const std = @import("std");
const network_mod = @import("protocol.zig");

pub const default_config_path = "/etc/WireNode/config.json";
pub const ui_bind_host = "0.0.0.0";
pub const ui_port: u16 = 17877;
pub const fixed_string_capacity: usize = 256;
pub const default_client_id = "wirenode-macos";
pub const default_client_name = "WireNode";
pub const default_stream_name = "Mac System Audio";

pub const FixedString = struct {
    buf: [fixed_string_capacity]u8 = [_]u8{0} ** fixed_string_capacity,
    len: u16 = 0,

    pub fn init(value: []const u8) FixedString {
        var out: FixedString = .{};
        out.setLossy(value);
        return out;
    }

    pub fn slice(self: *const FixedString) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *FixedString, value: []const u8) !void {
        if (value.len > self.buf.len) return error.StringTooLong;
        @memset(self.buf[0..], 0);
        @memcpy(self.buf[0..value.len], value);
        self.len = @intCast(value.len);
    }

    pub fn setLossy(self: *FixedString, value: []const u8) void {
        const next_len = @min(self.buf.len, value.len);
        @memset(self.buf[0..], 0);
        @memcpy(self.buf[0..next_len], value[0..next_len]);
        self.len = @intCast(next_len);
    }
};

pub const Config = struct {
    enabled: bool,
    host: FixedString,
    port: u16,
    client_id: FixedString,
    client_name: FixedString,
    stream_name: FixedString,
    capture_mode: network_mod.CaptureMode,
    sample_rate_hz: u32,
    channels: u8,
    frames_per_packet: u16,
    tone_hz: f32,

    pub fn defaults() Config {
        return .{
            .enabled = true,
            .host = FixedString.init("127.0.0.1"),
            .port = 45920,
            .client_id = FixedString.init(default_client_id),
            .client_name = FixedString.init(default_client_name),
            .stream_name = FixedString.init(default_stream_name),
            .capture_mode = .system_default,
            .sample_rate_hz = 48_000,
            .channels = 2,
            .frames_per_packet = 64,
            .tone_hz = 440.0,
        };
    }
};

const StoredConfig = struct {
    enabled: bool = true,
    host: []const u8 = "127.0.0.1",
    port: u16 = 45920,
    client_id: []const u8 = default_client_id,
    client_name: []const u8 = default_client_name,
    stream_name: []const u8 = default_stream_name,
    capture_mode: network_mod.CaptureMode = .system_default,
    sample_rate_hz: u32 = 48_000,
    channels: u8 = 2,
    frames_per_packet: u16 = 64,
    tone_hz: f32 = 440.0,
};

pub fn loadPath(allocator: std.mem.Allocator, path: []const u8) !?Config {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const bytes = try file.readToEndAlloc(allocator, 128 * 1024);
    defer allocator.free(bytes);
    if (std.mem.trim(u8, bytes, &std.ascii.whitespace).len == 0) return null;

    const parsed = std.json.parseFromSlice(StoredConfig, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.UnexpectedEndOfInput,
        error.SyntaxError,
        error.InvalidNumber,
        error.Overflow,
        error.UnknownField,
        error.DuplicateField,
        error.MissingField,
        => return null,
        else => return err,
    };
    defer parsed.deinit();

    return try fromStored(parsed.value);
}

pub fn savePath(allocator: std.mem.Allocator, path: []const u8, config: Config) !void {
    const parent_dir = std.fs.path.dirname(path) orelse return error.InvalidConfigPath;
    std.fs.makeDirAbsolute(parent_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();

    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    const writer = output.writer(allocator);
    try writer.writeAll("{\n");
    try writer.writeAll("  \"enabled\": ");
    try writer.writeAll(if (config.enabled) "true" else "false");
    try writer.writeAll(",\n  \"host\": ");
    try writeJsonString(writer, config.host.slice());
    try writer.print(",\n  \"port\": {d}", .{config.port});
    try writer.writeAll(",\n  \"client_id\": ");
    try writeJsonString(writer, config.client_id.slice());
    try writer.writeAll(",\n  \"client_name\": ");
    try writeJsonString(writer, config.client_name.slice());
    try writer.writeAll(",\n  \"stream_name\": ");
    try writeJsonString(writer, config.stream_name.slice());
    try writer.writeAll(",\n  \"capture_mode\": ");
    try writeJsonString(writer, captureModeLabel(config.capture_mode));
    try writer.print(",\n  \"sample_rate_hz\": {d}", .{config.sample_rate_hz});
    try writer.print(",\n  \"channels\": {d}", .{config.channels});
    try writer.print(",\n  \"frames_per_packet\": {d}", .{config.frames_per_packet});
    try writer.print(",\n  \"tone_hz\": {d}\n", .{config.tone_hz});
    try writer.writeAll("}\n");
    try file.writeAll(output.items);
}

fn toStored(config: Config) StoredConfig {
    return .{
        .enabled = config.enabled,
        .host = config.host.slice(),
        .port = config.port,
        .client_id = config.client_id.slice(),
        .client_name = config.client_name.slice(),
        .stream_name = config.stream_name.slice(),
        .capture_mode = config.capture_mode,
        .sample_rate_hz = config.sample_rate_hz,
        .channels = config.channels,
        .frames_per_packet = config.frames_per_packet,
        .tone_hz = config.tone_hz,
    };
}

fn fromStored(stored: StoredConfig) !Config {
    var config = Config.defaults();
    config.enabled = stored.enabled;
    try config.host.set(stored.host);
    config.port = stored.port;
    try config.client_id.set(defaultIfEmpty(stored.client_id, default_client_id));
    try config.client_name.set(defaultIfEmpty(stored.client_name, default_client_name));
    try config.stream_name.set(defaultIfEmpty(stored.stream_name, default_stream_name));
    config.capture_mode = stored.capture_mode;
    config.sample_rate_hz = stored.sample_rate_hz;
    config.channels = @max(@as(u8, 1), stored.channels);
    config.frames_per_packet = @max(@as(u16, 16), stored.frames_per_packet);
    config.tone_hz = stored.tone_hz;
    return config;
}

fn defaultIfEmpty(value: []const u8, fallback: []const u8) []const u8 {
    return if (value.len > 0) value else fallback;
}

pub fn captureModeLabel(mode: network_mod.CaptureMode) []const u8 {
    return switch (mode) {
        .tone => "tone",
        .silence => "silence",
        .stdin_f32le => "stdin_f32le",
        .system_default => "system_default",
    };
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => {
            if (byte < 0x20) {
                try writer.print("\\u{X:0>4}", .{byte});
            } else {
                try writer.writeByte(byte);
            }
        },
    };
    try writer.writeByte('"');
}
