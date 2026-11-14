#ifndef HENGEVM_VIRTIO_SND_H
#define HENGEVM_VIRTIO_SND_H

#include <pthread.h>
#include <stdatomic.h>

#include "virtio.h"

/* virtio-snd (virtio 1.2, section 5.14) with one output stream: the
   device Linux's snd_virtio drives.

   The guest's PCM goes into a ring here; a host backend (CoreAudio on the Mac)
   pulls it out on its own thread with hv_virtio_snd_pull. A transmit buffer goes
   back to the guest only once its audio has been pulled, which is what paces the
   guest's audio clock. Without a backend the ring drains at the stream's rate by
   the wall clock, so the guest still runs at the right speed. */
#define HV_VSND_RING (1u << 18)   /* bytes: over a second of 48 kHz stereo 16-bit */
#define HV_VSND_PENDING 64

/* PCM formats and rates, as the spec numbers them (the ones this device offers). */
#define HV_VSND_FMT_S16 5
#define HV_VSND_FMT_S32 17
#define HV_VSND_FMT_FLOAT 19
#define HV_VSND_RATE_44100 6
#define HV_VSND_RATE_48000 7

typedef struct HvVirtioSndBackend {
    /* Called on the CPU thread. Return 0 if the host can play this. */
    int (*start)(void *opaque, unsigned channels, unsigned format, unsigned rate_hz);
    void (*stop)(void *opaque);
    void *opaque;
} HvVirtioSndBackend;

typedef struct HvVirtioSnd {
    HvVirtio vio;
    HvVirtioSndBackend backend;
    /* the output stream's parameters (set by PCM_SET_PARAMS) */
    unsigned channels, format, rate, frame_bytes, rate_hz;
    uint32_t buffer_bytes, period_bytes;
    int prepared, running;
    /* ring: written by the CPU thread, read by the backend */
    uint8_t *ring;
    _Atomic uint64_t written, consumed;
    uint64_t clock_start_ns, clock_start_consumed; /* no backend: wall-clock drain */
    /* transmit buffers waiting for their audio to be played, in order */
    HvVirtqElem pending[HV_VSND_PENDING];
    uint64_t pending_end[HV_VSND_PENDING]; /* `written` after this buffer's data */
    uint32_t phead, pcopy, ptail; /* pcopy: next one whose audio is not yet in the ring */
    uint64_t underruns, xfers;
    /* HV_VSND_CONTROLS: "Master Playback Volume" (0-100, both channels) and "Master Playback Switch" */
    int controls;
    int volume[2], on[2];
    _Atomic int muted;                     /* both switches off: the backend plays silence */
    int notify_pending[2];                 /* a CTL_NOTIFY waits for an event buffer */
    void (*on_control)(void *opaque, int percent, int muted); /* a guest write that changed a control */
    void *cb_opaque;
} HvVirtioSnd;

#define HV_VSND_CONTROLS 1 /* the control elements (VIRTIO_SND_F_CTLS); Linux only: the Mac's device stays as it was */

HvVirtioSnd *hv_virtio_snd_create(HvMachine *m, HvPcie *bus, int flags);
/* Under the device lock: the host's volume, 0-100. The guest is told with a CTL_NOTIFY event. */
void hv_virtio_snd_set_volume(HvVirtioSnd *d, int percent);
/* CPU thread, each tick: return played buffers to the guest. */
void hv_virtio_snd_poll(HvVirtioSnd *d);
/* Backend thread: take up to `len` bytes of PCM; the rest of `buf` is silence, and all of it while muted. Returns bytes taken. */
uint32_t hv_virtio_snd_pull(HvVirtioSnd *d, void *buf, uint32_t len);

#endif
