const std = @import("std");

pub const ClientPlatform = enum(u8) {
    macos,
    linux,
    windows,
};

pub const CaptureMode = enum(u8) {
    tone,
    silence,
    stdin_f32le,
    system_default,
};

pub const TransportKind = enum(u8) {
    udp,
    quic,
};

pub const CodecKind = enum(u8) {
    pcm_float32,
    pcm_s16le,
    opus_lowdelay,
};

pub const ClockMode = enum(u8) {
    sender_timestamps,
    receiver_clock,
};

pub const PacketKind = enum(u8) {
    hello = 1,
    audio = 2,
    keepalive = 3,
    goodbye = 4,
};

pub const string_field_len = 64;

pub const PacketHeader = packed struct {
    magic: u32 = 0x57444E41,
    version: u8 = 1,
    kind: PacketKind = .audio,
    codec: CodecKind = .pcm_float32,
    channels: u8 = 2,
    sample_rate_hz: u32 = 48_000,
    frames: u16 = 64,
    sequence: u32 = 0,
    stream_id: u32 = 0,
    sender_time_ns: u64 = 0,
    reserved: u32 = 0,
};

pub const HelloPayload = extern struct {
    client_id: [string_field_len]u8 = zeroField(),
    client_name: [string_field_len]u8 = zeroField(),
    stream_name: [string_field_len]u8 = zeroField(),
    platform: ClientPlatform = .linux,
    capture_mode: CaptureMode = .tone,
    reserved: [2]u8 = .{ 0, 0 },
};

pub fn writeStringField(field: *[string_field_len]u8, value: []const u8) void {
    field.* = zeroField();
    const len = @min(field.len - 1, value.len);
    @memcpy(field[0..len], value[0..len]);
}

pub fn readStringField(field: [string_field_len]u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, &field, 0) orelse field.len;
    return field[0..end];
}

fn zeroField() [string_field_len]u8 {
    return [_]u8{0} ** string_field_len;
}
