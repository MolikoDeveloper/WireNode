const std = @import("std");
const builtin = @import("builtin");
const network_mod = @import("protocol.zig");
const config_mod = @import("config.zig");
const state_mod = @import("state.zig");
const http_ui = @import("http_ui.zig");
const macos_capture = @import("macos_capture.zig");

const CliOptions = struct {
    config_path: []const u8 = config_mod.default_config_path,
    write_default_config: bool = false,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa_state.deinit();
        if (leaked == .leak) std.log.err("memory leak detected", .{});
    }
    const allocator = gpa_state.allocator();
    const options = try parseArgs(allocator);

    var config = config_mod.Config.defaults();
    if (try config_mod.loadPath(allocator, options.config_path)) |loaded| {
        config = loaded;
    }

    if (options.write_default_config) {
        try config_mod.savePath(allocator, options.config_path, config);
        return;
    }

    var shared = try state_mod.SharedState.init(allocator, options.config_path, config);
    defer shared.deinit();

    const ui_thread = try std.Thread.spawn(.{}, http_ui.serverMain, .{&shared});
    defer {
        shared.requestStop();
        ui_thread.join();
    }

    shared.setStatus(.waiting_for_config, "", "UI lista en http://<ip-de-este-mac>:17877");
    runSenderLoop(&shared) catch |err| {
        shared.setStatus(.@"error", "", @errorName(err));
        return err;
    };
}

fn parseArgs(allocator: std.mem.Allocator) !CliOptions {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var options = CliOptions{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--config-path")) {
            index += 1;
            if (index >= args.len) return error.MissingConfigPath;
            options.config_path = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--write-default-config")) {
            options.write_default_config = true;
            continue;
        }
        return error.UnknownArgument;
    }
    return options;
}

fn runSenderLoop(shared: *state_mod.SharedState) !void {
    while (!shared.shouldStop()) {
        const snapshot = shared.snapshot();
        if (!snapshot.config.enabled or snapshot.config.host.slice().len == 0) {
            shared.setStatus(.waiting_for_config, "", "Configura el host de WireDeck en la UI local.");
            std.Thread.sleep(std.time.ns_per_s);
            continue;
        }

        if (snapshot.config.capture_mode == .system_default) {
            runSystemDefaultSession(shared, snapshot.revision, snapshot.config) catch |err| {
                shared.setStatus(.degraded, "", @errorName(err));
                std.Thread.sleep(2 * std.time.ns_per_s);
            };
            continue;
        }

        runUdpSession(shared, snapshot.revision, snapshot.config) catch |err| {
            shared.setStatus(.@"error", snapshot.config.host.slice(), @errorName(err));
            std.Thread.sleep(2 * std.time.ns_per_s);
        };
    }
}

fn runSystemDefaultSession(shared: *state_mod.SharedState, revision: u64, config: config_mod.Config) !void {
    if (builtin.os.tag != .macos) return error.UnsupportedPlatform;
    if (!macos_capture.supported()) return error.UnsupportedMacOSVersion;

    var backend_error: [256]u8 = [_]u8{0} ** 256;
    var capture = macos_capture.CaptureDevice.start(config.channels, config.frames_per_packet, false, &backend_error) catch |err| {
        const message = std.mem.sliceTo(&backend_error, 0);
        if (message.len > 0) {
            shared.setStatus(.degraded, "", message);
        }
        return err;
    };
    defer capture.stop();

    if (std.mem.sliceTo(&backend_error, 0).len > 0) {
        shared.setStatus(.degraded, "", std.mem.sliceTo(&backend_error, 0));
    } else {
        shared.setStatus(.idle, "", "Esperando audio del sistema o permiso de captura.");
    }
    try runUdpCaptureSession(shared, revision, config, &capture);
}

fn runUdpSession(shared: *state_mod.SharedState, revision: u64, config: config_mod.Config) !void {
    const server = try std.net.Address.resolveIp(config.host.slice(), config.port);
    const sock = try std.posix.socket(server.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(sock);

    const endpoint = try std.fmt.allocPrint(shared.allocator, "{s}:{d}", .{ config.host.slice(), config.port });
    defer shared.allocator.free(endpoint);

    const stream_id: u32 = @truncate(@as(u64, @intCast(std.time.nanoTimestamp())));
    var hello_header = network_mod.PacketHeader{
        .kind = .hello,
        .codec = .pcm_float32,
        .channels = config.channels,
        .sample_rate_hz = config.sample_rate_hz,
        .frames = config.frames_per_packet,
        .stream_id = stream_id,
        .sender_time_ns = @intCast(std.time.nanoTimestamp()),
    };
    var hello_payload = network_mod.HelloPayload{
        .platform = .macos,
        .capture_mode = config.capture_mode,
    };
    network_mod.writeStringField(&hello_payload.client_id, config.client_id.slice());
    network_mod.writeStringField(&hello_payload.client_name, config.client_name.slice());
    network_mod.writeStringField(&hello_payload.stream_name, config.stream_name.slice());
    try sendPacket(sock, server, std.mem.asBytes(&hello_header), std.mem.asBytes(&hello_payload));

    var packet_index: u32 = 0;
    var phase: f32 = 0.0;
    var last_hello_ns: i128 = std.time.nanoTimestamp();
    var last_keepalive_ns: i128 = std.time.nanoTimestamp();

    const sample_capacity = @as(usize, config.frames_per_packet) * @as(usize, config.channels);
    var sample_storage = try shared.allocator.alloc(f32, sample_capacity);
    defer shared.allocator.free(sample_storage);

    const packet_capacity = @sizeOf(network_mod.PacketHeader) + sample_capacity * @sizeOf(f32);
    var packet_buffer = try shared.allocator.alloc(u8, packet_capacity);
    defer shared.allocator.free(packet_buffer);

    var stdin = std.fs.File.stdin();
    while (!shared.shouldStop()) {
        if (shared.currentRevision() != revision) break;

        const frame_count = switch (config.capture_mode) {
            .tone => generateTone(sample_storage, config.channels, config.frames_per_packet, config.tone_hz, config.sample_rate_hz, &phase),
            .silence => generateSilence(sample_storage, config.channels, config.frames_per_packet),
            .stdin_f32le => try readStdinFloat32(&stdin, sample_storage, config.channels, config.frames_per_packet),
            .system_default => unreachable,
        };
        if (frame_count == 0) break;

        var header = network_mod.PacketHeader{
            .kind = .audio,
            .codec = .pcm_float32,
            .channels = config.channels,
            .sample_rate_hz = config.sample_rate_hz,
            .frames = @intCast(frame_count),
            .sequence = packet_index,
            .stream_id = stream_id,
            .sender_time_ns = @intCast(std.time.nanoTimestamp()),
        };

        const payload_bytes = frameCountBytes(frame_count, config.channels, @sizeOf(f32));
        @memcpy(packet_buffer[0..@sizeOf(network_mod.PacketHeader)], std.mem.asBytes(&header));
        @memcpy(
            packet_buffer[@sizeOf(network_mod.PacketHeader) .. @sizeOf(network_mod.PacketHeader) + payload_bytes],
            std.mem.sliceAsBytes(sample_storage[0 .. frame_count * config.channels]),
        );
        _ = try std.posix.sendto(sock, packet_buffer[0 .. @sizeOf(network_mod.PacketHeader) + payload_bytes], 0, &server.any, server.getOsSockLen());
        shared.markPacketSent(endpoint);

        packet_index +%= 1;
        if (std.time.nanoTimestamp() - last_hello_ns >= 2 * std.time.ns_per_s) {
            hello_header.sender_time_ns = @intCast(std.time.nanoTimestamp());
            try sendPacket(sock, server, std.mem.asBytes(&hello_header), std.mem.asBytes(&hello_payload));
            last_hello_ns = std.time.nanoTimestamp();
        }
        if (std.time.nanoTimestamp() - last_keepalive_ns >= std.time.ns_per_s) {
            var keepalive = header;
            keepalive.kind = .keepalive;
            keepalive.frames = 0;
            try sendPacket(sock, server, std.mem.asBytes(&keepalive), "");
            last_keepalive_ns = std.time.nanoTimestamp();
        }

        const sleep_ns = @as(u64, frame_count) * std.time.ns_per_s / config.sample_rate_hz;
        std.Thread.sleep(sleep_ns);
    }

    var goodbye = hello_header;
    goodbye.kind = .goodbye;
    goodbye.frames = 0;
    goodbye.sequence = packet_index;
    goodbye.sender_time_ns = @intCast(std.time.nanoTimestamp());
    try sendPacket(sock, server, std.mem.asBytes(&goodbye), "");
}

fn runUdpCaptureSession(
    shared: *state_mod.SharedState,
    revision: u64,
    config: config_mod.Config,
    capture: *macos_capture.CaptureDevice,
) !void {
    const server = try std.net.Address.resolveIp(config.host.slice(), config.port);
    const sock = try std.posix.socket(server.any.family, std.posix.SOCK.DGRAM, std.posix.IPPROTO.UDP);
    defer std.posix.close(sock);

    const endpoint = try std.fmt.allocPrint(shared.allocator, "{s}:{d}", .{ config.host.slice(), config.port });
    defer shared.allocator.free(endpoint);

    const stream_id: u32 = @truncate(@as(u64, @intCast(std.time.nanoTimestamp())));
    var sample_rate_hz: u32 = config.sample_rate_hz;
    var channel_count: u32 = config.channels;
    var hello_header = network_mod.PacketHeader{
        .kind = .hello,
        .codec = .pcm_float32,
        .channels = @intCast(channel_count),
        .sample_rate_hz = sample_rate_hz,
        .frames = config.frames_per_packet,
        .stream_id = stream_id,
        .sender_time_ns = @intCast(std.time.nanoTimestamp()),
    };
    var hello_payload = network_mod.HelloPayload{
        .platform = .macos,
        .capture_mode = .system_default,
    };
    network_mod.writeStringField(&hello_payload.client_id, config.client_id.slice());
    network_mod.writeStringField(&hello_payload.client_name, config.client_name.slice());
    network_mod.writeStringField(&hello_payload.stream_name, config.stream_name.slice());
    try sendPacket(sock, server, std.mem.asBytes(&hello_header), std.mem.asBytes(&hello_payload));

    var packet_index: u32 = 0;
    var last_hello_ns: i128 = std.time.nanoTimestamp();
    var last_keepalive_ns: i128 = std.time.nanoTimestamp();

    const sample_capacity = @as(usize, config.frames_per_packet) * @max(@as(usize, config.channels), 2);
    var sample_storage = try shared.allocator.alloc(f32, sample_capacity);
    defer shared.allocator.free(sample_storage);

    const packet_capacity = @sizeOf(network_mod.PacketHeader) + sample_capacity * @sizeOf(f32);
    var packet_buffer = try shared.allocator.alloc(u8, packet_capacity);
    defer shared.allocator.free(packet_buffer);

    while (!shared.shouldStop()) {
        if (shared.currentRevision() != revision) break;

        var actual_rate_hz: u32 = sample_rate_hz;
        var actual_channels: u32 = channel_count;
        const frame_count = capture.read(
            sample_storage,
            config.frames_per_packet,
            250,
            &actual_rate_hz,
            &actual_channels,
        );
        if (frame_count > 0) {
            sample_rate_hz = actual_rate_hz;
            channel_count = actual_channels;
            hello_header.sample_rate_hz = sample_rate_hz;
            hello_header.channels = @intCast(channel_count);

            var header = network_mod.PacketHeader{
                .kind = .audio,
                .codec = .pcm_float32,
                .channels = @intCast(channel_count),
                .sample_rate_hz = sample_rate_hz,
                .frames = @intCast(frame_count),
                .sequence = packet_index,
                .stream_id = stream_id,
                .sender_time_ns = @intCast(std.time.nanoTimestamp()),
            };

            const payload_bytes = frameCountBytes(frame_count, @intCast(channel_count), @sizeOf(f32));
            @memcpy(packet_buffer[0..@sizeOf(network_mod.PacketHeader)], std.mem.asBytes(&header));
            @memcpy(
                packet_buffer[@sizeOf(network_mod.PacketHeader) .. @sizeOf(network_mod.PacketHeader) + payload_bytes],
                std.mem.sliceAsBytes(sample_storage[0 .. frame_count * channel_count]),
            );
            _ = try std.posix.sendto(sock, packet_buffer[0 .. @sizeOf(network_mod.PacketHeader) + payload_bytes], 0, &server.any, server.getOsSockLen());
            shared.markPacketSent(endpoint);
            packet_index +%= 1;
        }

        const now_ns = std.time.nanoTimestamp();
        if (now_ns - last_hello_ns >= 2 * std.time.ns_per_s) {
            hello_header.sender_time_ns = @intCast(now_ns);
            try sendPacket(sock, server, std.mem.asBytes(&hello_header), std.mem.asBytes(&hello_payload));
            last_hello_ns = now_ns;
        }
        if (now_ns - last_keepalive_ns >= std.time.ns_per_s) {
            var keepalive = hello_header;
            keepalive.kind = .keepalive;
            keepalive.frames = 0;
            keepalive.sequence = packet_index;
            keepalive.sender_time_ns = @intCast(now_ns);
            try sendPacket(sock, server, std.mem.asBytes(&keepalive), "");
            last_keepalive_ns = now_ns;
        }
    }

    var goodbye = hello_header;
    goodbye.kind = .goodbye;
    goodbye.frames = 0;
    goodbye.sequence = packet_index;
    goodbye.sender_time_ns = @intCast(std.time.nanoTimestamp());
    try sendPacket(sock, server, std.mem.asBytes(&goodbye), "");
}

fn sendPacket(sock: std.posix.socket_t, server: std.net.Address, header_bytes: []const u8, payload_bytes: []const u8) !void {
    var buffer: [@sizeOf(network_mod.PacketHeader) + @sizeOf(network_mod.HelloPayload)]u8 = undefined;
    const total = header_bytes.len + payload_bytes.len;
    if (total > buffer.len) {
        var packet = try std.heap.page_allocator.alloc(u8, total);
        defer std.heap.page_allocator.free(packet);
        @memcpy(packet[0..header_bytes.len], header_bytes);
        @memcpy(packet[header_bytes.len..total], payload_bytes);
        _ = try std.posix.sendto(sock, packet, 0, &server.any, server.getOsSockLen());
        return;
    }
    @memcpy(buffer[0..header_bytes.len], header_bytes);
    @memcpy(buffer[header_bytes.len..total], payload_bytes);
    _ = try std.posix.sendto(sock, buffer[0..total], 0, &server.any, server.getOsSockLen());
}

fn frameCountBytes(frames: usize, channels: u8, sample_size: usize) usize {
    return frames * @as(usize, channels) * sample_size;
}

fn generateTone(storage: []f32, channels: u8, frames_per_packet: u16, tone_hz: f32, sample_rate_hz: u32, phase: *f32) usize {
    const frames: usize = frames_per_packet;
    const chan_count: usize = channels;
    const phase_step = 2.0 * std.math.pi * tone_hz / @as(f32, @floatFromInt(sample_rate_hz));
    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        const sample = @sin(phase.*) * 0.20;
        phase.* += phase_step;
        var channel_index: usize = 0;
        while (channel_index < chan_count) : (channel_index += 1) {
            storage[frame * chan_count + channel_index] = sample;
        }
    }
    return frames;
}

fn generateSilence(storage: []f32, channels: u8, frames_per_packet: u16) usize {
    const sample_count = @as(usize, channels) * @as(usize, frames_per_packet);
    @memset(storage[0..sample_count], 0.0);
    return frames_per_packet;
}

fn readStdinFloat32(stdin: *std.fs.File, storage: []f32, channels: u8, frames_per_packet: u16) !usize {
    const bytes_per_packet = @as(usize, channels) * @as(usize, frames_per_packet) * @sizeOf(f32);
    const target = std.mem.sliceAsBytes(storage[0 .. @as(usize, channels) * @as(usize, frames_per_packet)]);
    var offset: usize = 0;
    while (offset < bytes_per_packet) {
        const bytes_read = try stdin.read(target[offset..bytes_per_packet]);
        if (bytes_read == 0) break;
        offset += bytes_read;
    }
    if (offset == 0) return 0;
    return offset / (@as(usize, channels) * @sizeOf(f32));
}
