#ifndef MUCKE_AUDIO_TAP_PCM_H
#define MUCKE_AUDIO_TAP_PCM_H

#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#if __has_attribute(nonblocking)
#define MUCKE_AUDIO_REALTIME __attribute__((nonblocking))
#else
#define MUCKE_AUDIO_REALTIME
#endif

_Static_assert(__atomic_always_lock_free(sizeof(uint64_t), 0), "PCM-Zähler müssen lockfrei sein");
_Static_assert(__atomic_always_lock_free(sizeof(float), 0), "PCM-Lautstärke muss lockfrei sein");

enum { MuckeAudioPCMSlots = 32, MuckeAudioPCMMaxFrames = 8192 };

typedef struct {
    float samples[MuckeAudioPCMMaxFrames];
    uint64_t sequence;
    size_t frames;
    float volume;
} MuckeAudioPCMSlot;

typedef struct {
    _Atomic uint64_t published;
    _Atomic uint64_t released;
    _Atomic uint64_t nextSequence;
    _Atomic uint64_t lastDrop;
    _Atomic float volume;
    uint32_t channels;
    bool interleaved;
    MuckeAudioPCMSlot slots[MuckeAudioPCMSlots];
} MuckeAudioPCM;

typedef struct {
    float * _Nullable samples;
    uint64_t sequence;
    size_t frames;
    float volume;
} MuckeAudioPCMBlock;

static inline void * _Nullable MuckeAudioPCMCreate(uint32_t channels, bool interleaved)
{
    if (channels == 0 || channels > 32) {
        return NULL;
    }
    MuckeAudioPCM *pcm = malloc(sizeof(*pcm));
    if (!pcm) {
        return NULL;
    }
    // Jede Speicherseite vor dem ersten Zugriff vom IO-Thread anfassen.
    for (size_t i = 0; i < sizeof(*pcm); i += 4096) {
        ((volatile unsigned char *)pcm)[i] = 0;
    }
    ((volatile unsigned char *)pcm)[sizeof(*pcm) - 1] = 0;
    atomic_init(&pcm->published, 0);
    atomic_init(&pcm->released, 0);
    atomic_init(&pcm->nextSequence, 1);
    atomic_init(&pcm->lastDrop, 0);
    atomic_init(&pcm->volume, 1.0f);
    pcm->channels = channels;
    pcm->interleaved = interleaved;
    return pcm;
}

static inline void MuckeAudioPCMFree(void * _Nonnull storage)
{
    free(storage);
}

static inline void MuckeAudioPCMSetVolume(void * _Nonnull storage, float volume)
{
    MuckeAudioPCM *pcm = storage;
    atomic_store_explicit(&pcm->volume, volume, memory_order_relaxed);
}

// Ein Schreiber (CoreAudio), ein Leser (Analyse-Queue). Der Leser gibt einen
// Slot erst nach der Verarbeitung frei. Bei Überlauf fällt der neue Block weg.
static inline MUCKE_AUDIO_REALTIME bool MuckeAudioPCMSubmit(void * _Nonnull storage, const AudioBufferList * _Nonnull input)
{
    MuckeAudioPCM *pcm = storage;
    if (input->mNumberBuffers == 0 || input->mBuffers[0].mDataByteSize == 0) {
        return false;
    }

    const uint64_t sequence = atomic_load_explicit(&pcm->nextSequence, memory_order_relaxed);
    atomic_store_explicit(&pcm->nextSequence, sequence + 1, memory_order_release);

    const uint64_t position = atomic_load_explicit(&pcm->published, memory_order_relaxed);
    const uint64_t released = atomic_load_explicit(&pcm->released, memory_order_acquire);
    const AudioBuffer *buffers = input->mBuffers;
    const uint32_t channels = pcm->channels;
    const bool interleaved = pcm->interleaved || input->mNumberBuffers == 1;
    const size_t bytesPerFrame = sizeof(float) * (interleaved ? channels : 1);
    const size_t bytes = buffers[0].mDataByteSize;
    const size_t frames = bytes / bytesPerFrame;
    if (position - released == MuckeAudioPCMSlots || frames > MuckeAudioPCMMaxFrames
        || bytes % bytesPerFrame != 0 || !buffers[0].mData
        || buffers[0].mNumberChannels != (interleaved ? channels : 1)
        || (!interleaved && input->mNumberBuffers != channels)) {
        atomic_store_explicit(&pcm->lastDrop, sequence, memory_order_release);
        return false;
    }

    MuckeAudioPCMSlot *slot = &pcm->slots[position % MuckeAudioPCMSlots];
    const float *first = buffers[0].mData;
    slot->volume = atomic_load_explicit(&pcm->volume, memory_order_relaxed);
    const float scale = 1.0f / (float)channels;
    if (interleaved && channels == 2) {
        for (size_t i = 0; i < frames; ++i) {
            slot->samples[i] = (first[2 * i] + first[2 * i + 1]) * 0.5f;
        }
    } else if (interleaved && channels > 1) {
        for (size_t i = 0; i < frames; ++i) {
            float sum = 0;
            for (uint32_t c = 0; c < channels; ++c) {
                sum += first[i * channels + c];
            }
            slot->samples[i] = sum * scale;
        }
    } else {
        for (size_t i = 0; i < frames; ++i) {
            slot->samples[i] = first[i];
        }
        for (uint32_t c = 1; c < channels; ++c) {
            const AudioBuffer *buffer = &buffers[c];
            if (!buffer->mData || buffer->mNumberChannels != 1 || buffer->mDataByteSize != bytes) {
                atomic_store_explicit(&pcm->lastDrop, sequence, memory_order_release);
                return false;
            }
            const float *source = buffer->mData;
            for (size_t i = 0; i < frames; ++i) {
                slot->samples[i] += source[i];
            }
        }
        if (channels > 1) {
            for (size_t i = 0; i < frames; ++i) {
                slot->samples[i] *= scale;
            }
        }
    }

    slot->frames = frames;
    slot->sequence = sequence;
    atomic_store_explicit(&pcm->published, position + 1, memory_order_release);
    return true;
}

static MUCKE_AUDIO_REALTIME OSStatus MuckeAudioPCMIOProc(AudioObjectID device, const AudioTimeStamp * _Nonnull now,
                                    const AudioBufferList * _Nonnull input, const AudioTimeStamp * _Nonnull inputTime,
                                    AudioBufferList * _Nonnull output, const AudioTimeStamp * _Nonnull outputTime,
                                    void * _Nullable storage)
{
    if (storage) {
        MuckeAudioPCMSubmit(storage, input);
    }
    return noErr;
}

static inline OSStatus MuckeAudioPCMInstall(void * _Nonnull storage, AudioObjectID device,
                                            AudioDeviceIOProcID _Nullable * _Nonnull proc)
{
    return AudioDeviceCreateIOProcID(device, MuckeAudioPCMIOProc, storage, proc);
}

static inline MuckeAudioPCMBlock MuckeAudioPCMPeek(void * _Nonnull storage)
{
    MuckeAudioPCM *pcm = storage;
    const uint64_t position = atomic_load_explicit(&pcm->released, memory_order_relaxed);
    const uint64_t published = atomic_load_explicit(&pcm->published, memory_order_acquire);
    if (position == published) {
        return (MuckeAudioPCMBlock){ 0 };
    }

    MuckeAudioPCMSlot *slot = &pcm->slots[position % MuckeAudioPCMSlots];
    return (MuckeAudioPCMBlock){
        .samples = slot->samples, .sequence = slot->sequence, .frames = slot->frames, .volume = slot->volume
    };
}

static inline void MuckeAudioPCMConsume(void * _Nonnull storage)
{
    MuckeAudioPCM *pcm = storage;
    const uint64_t position = atomic_load_explicit(&pcm->released, memory_order_relaxed);
    atomic_store_explicit(&pcm->released, position + 1, memory_order_release);
}

static inline uint64_t MuckeAudioPCMNextSequence(void * _Nonnull storage)
{
    MuckeAudioPCM *pcm = storage;
    return atomic_load_explicit(&pcm->nextSequence, memory_order_acquire);
}

static inline uint64_t MuckeAudioPCMLastDrop(void * _Nonnull storage)
{
    MuckeAudioPCM *pcm = storage;
    return atomic_load_explicit(&pcm->lastDrop, memory_order_acquire);
}

#undef MUCKE_AUDIO_REALTIME

#endif
