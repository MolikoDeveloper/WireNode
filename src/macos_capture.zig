const std = @import("std");
const c = @cImport({
    @cInclude("macos_capture_bridge.h");
});

pub const CaptureDevice = struct {
    handle: *c.WNMacCaptureHandle,

    pub fn start(channels: u8, frames_per_packet: u16, mute_output_locally: bool, error_buffer: *[256]u8) !CaptureDevice {
        var handle: ?*c.WNMacCaptureHandle = null;
        error_buffer.* = [_]u8{0} ** error_buffer.len;
        const config = c.WNMacCaptureConfig{
            .preferred_channels = channels,
            .frames_per_packet = frames_per_packet,
            .mute_output_locally = mute_output_locally,
        };
        const rc = c.wn_macos_capture_start(&config, &handle, error_buffer, error_buffer.len);
        if (rc != 0 or handle == null) {
            std.log.err("macOS capture start failed: rc={d} message={s}", .{ rc, std.mem.sliceTo(error_buffer, 0) });
            return error.MacOSCaptureStartFailed;
        }
        return .{ .handle = handle.? };
    }

    pub fn stop(self: *CaptureDevice) void {
        c.wn_macos_capture_stop(self.handle);
    }

    pub fn read(self: *CaptureDevice, storage: []f32, max_frames: usize, timeout_ms: u32, sample_rate_hz: *u32, channels: *u32) usize {
        return c.wn_macos_capture_read(self.handle, storage.ptr, max_frames, timeout_ms, sample_rate_hz, channels);
    }
};

pub fn supported() bool {
    return c.wn_macos_capture_supported();
}
