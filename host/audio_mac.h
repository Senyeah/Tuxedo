/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef TUXVM_AUDIO_MAC_H
#define TUXVM_AUDIO_MAC_H

#include "virtio_snd.h"

/* Play the guest's virtio-snd output on the Mac's default output device. */
void hv_audio_attach(HvVirtioSnd *d);
/* Stops and disposes the output unit, waiting for its last render callback. */
void hv_audio_detach(void);
/* The guest's stream is playing (an iOS app with the audio mode keeps running in the background). */
int hv_audio_playing(void);
/* Host thread, with the CPUs paused: stop the output unit (1), and start it again if it played (0). */
void hv_audio_hold(int on);
/* Called on a CPU's thread after the guest stops its stream, or NULL. */
extern void (*hv_audio_stopped)(void);

#endif
