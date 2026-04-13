#import "macos_capture_bridge.h"

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct WNMacCaptureHandle {
    AudioObjectID tap_id;
    AudioObjectID aggregate_device_id;
    AudioDeviceIOProcID io_proc_id;
    AudioStreamBasicDescription format;
    uint32_t sample_rate_hz;
    uint32_t source_channels;
    uint32_t output_channels;
    size_t frames_per_packet;
    bool stop_requested;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    float *ring;
    size_t ring_capacity_frames;
    size_t ring_read_frame;
    size_t ring_available_frames;
};

static void set_error_message(char *buffer, size_t buffer_len, NSString *message) {
    if (buffer == NULL || buffer_len == 0) return;
    const char *utf8 = message.UTF8String ?: "unknown";
    snprintf(buffer, buffer_len, "%s", utf8);
}

static NSString *status_description(OSStatus status) {
    UInt32 big_endian = CFSwapInt32HostToBig((uint32_t)status);
    char fourcc[5] = {0, 0, 0, 0, 0};
    memcpy(fourcc, &big_endian, sizeof(big_endian));
    BOOL printable = YES;
    for (size_t i = 0; i < 4; i += 1) {
        if (fourcc[i] < 32 || fourcc[i] > 126) {
            printable = NO;
            break;
        }
    }
    if (printable) {
        return [NSString stringWithFormat:@"OSStatus %d ('%4.4s')", (int)status, fourcc];
    }
    return [NSString stringWithFormat:@"OSStatus %d", (int)status];
}

static bool get_tap_format(AudioObjectID tap_id, AudioStreamBasicDescription *format) {
    UInt32 data_size = (UInt32)sizeof(*format);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioTapPropertyFormat,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    return AudioObjectGetPropertyData(tap_id, &address, 0, NULL, &data_size, format) == noErr;
}

static bool get_device_sample_rate(AudioObjectID device_id, Float64 *sample_rate) {
    UInt32 data_size = (UInt32)sizeof(*sample_rate);
    AudioObjectPropertyAddress address = {
        .mSelector = kAudioDevicePropertyNominalSampleRate,
        .mScope = kAudioObjectPropertyScopeGlobal,
        .mElement = kAudioObjectPropertyElementMain,
    };
    return AudioObjectGetPropertyData(device_id, &address, 0, NULL, &data_size, sample_rate) == noErr;
}

static bool ensure_ring_capacity(WNMacCaptureHandle *handle, size_t min_capacity_frames) {
    if (handle->ring_capacity_frames >= min_capacity_frames) return true;
    size_t next_capacity = handle->ring_capacity_frames > 0 ? handle->ring_capacity_frames : 4096;
    while (next_capacity < min_capacity_frames) next_capacity *= 2;

    float *next_ring = calloc(next_capacity * handle->output_channels, sizeof(float));
    if (next_ring == NULL) return false;

    if (handle->ring != NULL && handle->ring_available_frames > 0) {
        size_t first_chunk = handle->ring_available_frames;
        if (handle->ring_read_frame + first_chunk > handle->ring_capacity_frames) {
            first_chunk = handle->ring_capacity_frames - handle->ring_read_frame;
        }
        memcpy(next_ring,
               handle->ring + (handle->ring_read_frame * handle->output_channels),
               first_chunk * handle->output_channels * sizeof(float));
        if (handle->ring_available_frames > first_chunk) {
            memcpy(next_ring + (first_chunk * handle->output_channels),
                   handle->ring,
                   (handle->ring_available_frames - first_chunk) * handle->output_channels * sizeof(float));
        }
    }

    free(handle->ring);
    handle->ring = next_ring;
    handle->ring_capacity_frames = next_capacity;
    handle->ring_read_frame = 0;
    return true;
}

static float decode_sample(const void *base, UInt32 frame_index, UInt32 channel_index, const AudioStreamBasicDescription *format) {
    const bool is_float = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    const bool is_signed = (format->mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0;
    const UInt32 bytes_per_sample = format->mBitsPerChannel / 8;
    const UInt32 channel_count = format->mChannelsPerFrame > 0 ? format->mChannelsPerFrame : 1;
    const bool interleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    const uint8_t *bytes = (const uint8_t *)base;
    size_t sample_offset = 0;
    if (interleaved) {
        sample_offset = ((size_t)frame_index * channel_count + channel_index) * bytes_per_sample;
    } else {
        sample_offset = (size_t)frame_index * bytes_per_sample;
    }

    if (is_float && bytes_per_sample == sizeof(Float32)) {
        Float32 sample = 0.0f;
        memcpy(&sample, bytes + sample_offset, sizeof(sample));
        return sample;
    }
    if (is_float && bytes_per_sample == sizeof(Float64)) {
        Float64 sample = 0.0;
        memcpy(&sample, bytes + sample_offset, sizeof(sample));
        return (float)sample;
    }
    if (is_signed && bytes_per_sample == sizeof(int16_t)) {
        int16_t sample = 0;
        memcpy(&sample, bytes + sample_offset, sizeof(sample));
        return (float)sample / 32768.0f;
    }
    if (is_signed && bytes_per_sample == sizeof(int32_t)) {
        int32_t sample = 0;
        memcpy(&sample, bytes + sample_offset, sizeof(sample));
        return (float)sample / 2147483648.0f;
    }
    return 0.0f;
}

static void push_converted_audio(WNMacCaptureHandle *handle, const AudioBufferList *input_data) {
    if (input_data == NULL || input_data->mNumberBuffers == 0) return;
    const UInt32 source_channels = handle->source_channels > 0 ? handle->source_channels : (uint32_t)input_data->mNumberBuffers;
    const bool interleaved = (handle->format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    const UInt32 bytes_per_frame = handle->format.mBytesPerFrame > 0 ? handle->format.mBytesPerFrame : (handle->format.mBitsPerChannel / 8);
    if (bytes_per_frame == 0) return;

    const AudioBuffer first_buffer = input_data->mBuffers[0];
    const UInt32 frame_count = first_buffer.mDataByteSize / bytes_per_frame;
    if (frame_count == 0) return;

    pthread_mutex_lock(&handle->mutex);
    if (!ensure_ring_capacity(handle, handle->ring_available_frames + frame_count + handle->frames_per_packet)) {
        pthread_mutex_unlock(&handle->mutex);
        return;
    }

    size_t write_frame = (handle->ring_read_frame + handle->ring_available_frames) % handle->ring_capacity_frames;
    for (UInt32 frame = 0; frame < frame_count; frame += 1) {
        for (UInt32 out_channel = 0; out_channel < handle->output_channels; out_channel += 1) {
            UInt32 source_channel = source_channels == 1 ? 0 : (out_channel < source_channels ? out_channel : source_channels - 1);
            const AudioBuffer *buffer = interleaved ? &input_data->mBuffers[0] : &input_data->mBuffers[source_channel];
            float value = decode_sample(buffer->mData, frame, interleaved ? source_channel : 0, &handle->format);
            handle->ring[(write_frame * handle->output_channels) + out_channel] = value;
        }
        write_frame = (write_frame + 1) % handle->ring_capacity_frames;
    }
    handle->ring_available_frames += frame_count;
    pthread_cond_signal(&handle->cond);
    pthread_mutex_unlock(&handle->mutex);
}

bool wn_macos_capture_supported(void) {
    if (@available(macOS 14.2, *)) {
        return true;
    }
    return false;
}

int wn_macos_capture_start(const WNMacCaptureConfig *config, WNMacCaptureHandle **out_handle, char *error_buffer, size_t error_buffer_len) {
    if (out_handle == NULL || config == NULL) return -1;
    *out_handle = NULL;
    if (!wn_macos_capture_supported()) {
        set_error_message(error_buffer, error_buffer_len, @"Core Audio taps require macOS 14.2 or newer.");
        return -2;
    }

    @autoreleasepool {
        WNMacCaptureHandle *handle = calloc(1, sizeof(*handle));
        if (handle == NULL) {
            set_error_message(error_buffer, error_buffer_len, @"Out of memory.");
            return -3;
        }
        handle->output_channels = config->preferred_channels > 0 ? config->preferred_channels : 2;
        handle->frames_per_packet = config->frames_per_packet > 0 ? config->frames_per_packet : 64;
        pthread_mutex_init(&handle->mutex, NULL);
        pthread_cond_init(&handle->cond, NULL);

        CATapDescription *tap = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
        tap.privateTap = YES;
        tap.name = @"WireNode System Audio";
        tap.UUID = [NSUUID UUID];
        tap.muteBehavior = config->mute_output_locally ? CATapMutedWhenTapped : CATapUnmuted;

        OSStatus status = AudioHardwareCreateProcessTap(tap, &handle->tap_id);
        if (status != noErr) {
            set_error_message(error_buffer, error_buffer_len, [NSString stringWithFormat:@"Unable to create process tap: %@", status_description(status)]);
            wn_macos_capture_stop(handle);
            return (int)status;
        }

        NSDictionary *subtap = @{
            @kAudioSubTapUIDKey: tap.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey: @YES,
        };
        NSDictionary *aggregate = @{
            @kAudioAggregateDeviceNameKey: @"WireNode System Audio Capture",
            @kAudioAggregateDeviceUIDKey: [@"com.wiredeck.wirenode.aggregate." stringByAppendingString:NSUUID.UUID.UUIDString],
            @kAudioAggregateDeviceTapListKey: @[ subtap ],
            @kAudioAggregateDeviceTapAutoStartKey: @NO,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
        };
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &handle->aggregate_device_id);
        if (status != noErr) {
            set_error_message(error_buffer, error_buffer_len, [NSString stringWithFormat:@"Unable to create aggregate device: %@", status_description(status)]);
            wn_macos_capture_stop(handle);
            return (int)status;
        }

        if (!get_tap_format(handle->tap_id, &handle->format)) {
            set_error_message(error_buffer, error_buffer_len, @"Unable to query tap format.");
            wn_macos_capture_stop(handle);
            return -4;
        }
        handle->source_channels = handle->format.mChannelsPerFrame > 0 ? handle->format.mChannelsPerFrame : 2;
        handle->sample_rate_hz = handle->format.mSampleRate > 0 ? (uint32_t)llround(handle->format.mSampleRate) : 0;
        if (handle->sample_rate_hz == 0) {
            Float64 nominal = 0;
            if (get_device_sample_rate(handle->aggregate_device_id, &nominal) && nominal > 0) {
                handle->sample_rate_hz = (uint32_t)llround(nominal);
            }
        }
        if (handle->sample_rate_hz == 0) handle->sample_rate_hz = 48000;
        if (!ensure_ring_capacity(handle, handle->frames_per_packet * 256)) {
            set_error_message(error_buffer, error_buffer_len, @"Unable to allocate capture ring buffer.");
            wn_macos_capture_stop(handle);
            return -5;
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&handle->io_proc_id, handle->aggregate_device_id, NULL, ^(const AudioTimeStamp *inNow, const AudioBufferList *inInputData, const AudioTimeStamp *inInputTime, AudioBufferList *outOutputData, const AudioTimeStamp *inOutputTime) {
            (void)inNow;
            (void)inInputTime;
            (void)outOutputData;
            (void)inOutputTime;
            if (handle->stop_requested) return;
            push_converted_audio(handle, inInputData);
        });
        if (status != noErr) {
            set_error_message(error_buffer, error_buffer_len, [NSString stringWithFormat:@"Unable to create IO proc: %@", status_description(status)]);
            wn_macos_capture_stop(handle);
            return (int)status;
        }

        status = AudioDeviceStart(handle->aggregate_device_id, handle->io_proc_id);
        if (status != noErr) {
            set_error_message(error_buffer, error_buffer_len, [NSString stringWithFormat:@"Unable to start audio capture. macOS may still need to grant system audio permission: %@", status_description(status)]);
            wn_macos_capture_stop(handle);
            return (int)status;
        }

        *out_handle = handle;
        return 0;
    }
}

void wn_macos_capture_stop(WNMacCaptureHandle *handle) {
    if (handle == NULL) return;
    handle->stop_requested = true;
    pthread_mutex_lock(&handle->mutex);
    pthread_cond_broadcast(&handle->cond);
    pthread_mutex_unlock(&handle->mutex);

    if (handle->aggregate_device_id != kAudioObjectUnknown && handle->io_proc_id != NULL) {
        AudioDeviceStop(handle->aggregate_device_id, handle->io_proc_id);
        AudioDeviceDestroyIOProcID(handle->aggregate_device_id, handle->io_proc_id);
        handle->io_proc_id = NULL;
    }
    if (handle->aggregate_device_id != kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(handle->aggregate_device_id);
        handle->aggregate_device_id = kAudioObjectUnknown;
    }
    if (handle->tap_id != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(handle->tap_id);
        handle->tap_id = kAudioObjectUnknown;
    }

    pthread_cond_destroy(&handle->cond);
    pthread_mutex_destroy(&handle->mutex);
    free(handle->ring);
    free(handle);
}

size_t wn_macos_capture_read(WNMacCaptureHandle *handle, float *dst_interleaved, size_t max_frames, uint32_t timeout_ms, uint32_t *out_sample_rate_hz, uint32_t *out_channels) {
    if (handle == NULL || dst_interleaved == NULL || max_frames == 0) return 0;

    pthread_mutex_lock(&handle->mutex);
    if (handle->ring_available_frames == 0 && !handle->stop_requested) {
        struct timespec deadline;
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += timeout_ms / 1000;
        deadline.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec += 1;
            deadline.tv_nsec -= 1000000000L;
        }
        pthread_cond_timedwait(&handle->cond, &handle->mutex, &deadline);
    }

    const size_t frames_to_copy = handle->ring_available_frames < max_frames ? handle->ring_available_frames : max_frames;
    if (frames_to_copy > 0) {
        size_t first_chunk = frames_to_copy;
        if (handle->ring_read_frame + first_chunk > handle->ring_capacity_frames) {
            first_chunk = handle->ring_capacity_frames - handle->ring_read_frame;
        }
        memcpy(dst_interleaved,
               handle->ring + (handle->ring_read_frame * handle->output_channels),
               first_chunk * handle->output_channels * sizeof(float));
        if (frames_to_copy > first_chunk) {
            memcpy(dst_interleaved + (first_chunk * handle->output_channels),
                   handle->ring,
                   (frames_to_copy - first_chunk) * handle->output_channels * sizeof(float));
        }
        handle->ring_read_frame = (handle->ring_read_frame + frames_to_copy) % handle->ring_capacity_frames;
        handle->ring_available_frames -= frames_to_copy;
    }

    if (out_sample_rate_hz != NULL) *out_sample_rate_hz = handle->sample_rate_hz;
    if (out_channels != NULL) *out_channels = handle->output_channels;
    pthread_mutex_unlock(&handle->mutex);
    return frames_to_copy;
}
