#ifndef WIRENODE_MACOS_CAPTURE_BRIDGE_H
#define WIRENODE_MACOS_CAPTURE_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WNMacCaptureHandle WNMacCaptureHandle;

typedef struct WNMacCaptureConfig {
    uint32_t preferred_channels;
    uint32_t frames_per_packet;
    bool mute_output_locally;
} WNMacCaptureConfig;

bool wn_macos_capture_supported(void);
int wn_macos_capture_start(const WNMacCaptureConfig *config, WNMacCaptureHandle **out_handle, char *error_buffer, size_t error_buffer_len);
void wn_macos_capture_stop(WNMacCaptureHandle *handle);
size_t wn_macos_capture_read(WNMacCaptureHandle *handle, float *dst_interleaved, size_t max_frames, uint32_t timeout_ms, uint32_t *out_sample_rate_hz, uint32_t *out_channels);

#ifdef __cplusplus
}
#endif

#endif
