const std = @import("std");
const config_mod = @import("config.zig");

pub const SenderState = enum {
    idle,
    waiting_for_config,
    sending,
    degraded,
    @"error",
};

pub const RuntimeStatus = struct {
    sender_state: SenderState,
    endpoint: config_mod.FixedString,
    last_error: config_mod.FixedString,
    last_packet_ns: i128,

    pub fn defaults() RuntimeStatus {
        return .{
            .sender_state = .idle,
            .endpoint = config_mod.FixedString.init(""),
            .last_error = config_mod.FixedString.init(""),
            .last_packet_ns = 0,
        };
    }
};

pub const SharedState = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    config_path: []u8,
    config_revision: u64 = 1,
    config: config_mod.Config,
    status: RuntimeStatus,
    stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const Snapshot = struct {
        revision: u64,
        config: config_mod.Config,
        status: RuntimeStatus,
    };

    pub fn init(allocator: std.mem.Allocator, config_path: []const u8, initial_config: config_mod.Config) !SharedState {
        return .{
            .allocator = allocator,
            .config_path = try allocator.dupe(u8, config_path),
            .config = initial_config,
            .status = RuntimeStatus.defaults(),
        };
    }

    pub fn deinit(self: *SharedState) void {
        self.allocator.free(self.config_path);
    }

    pub fn snapshot(self: *SharedState) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .revision = self.config_revision,
            .config = self.config,
            .status = self.status,
        };
    }

    pub fn replaceConfigAndPersist(self: *SharedState, next_config: config_mod.Config) !void {
        self.mutex.lock();
        self.config = next_config;
        self.config_revision += 1;
        const next_snapshot = self.config;
        const path = self.config_path;
        self.mutex.unlock();

        try config_mod.savePath(self.allocator, path, next_snapshot);
    }

    pub fn setStatus(self: *SharedState, sender_state: SenderState, endpoint: []const u8, last_error: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.status.sender_state = sender_state;
        self.status.endpoint.setLossy(endpoint);
        self.status.last_error.setLossy(last_error);
    }

    pub fn markPacketSent(self: *SharedState, endpoint: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.status.sender_state = .sending;
        self.status.endpoint.setLossy(endpoint);
        self.status.last_error.setLossy("");
        self.status.last_packet_ns = std.time.nanoTimestamp();
    }

    pub fn currentRevision(self: *SharedState) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.config_revision;
    }

    pub fn requestStop(self: *SharedState) void {
        self.stop_requested.store(true, .release);
    }

    pub fn shouldStop(self: *SharedState) bool {
        return self.stop_requested.load(.acquire);
    }
};
