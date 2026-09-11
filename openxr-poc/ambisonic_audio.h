#pragma once

#include <cstdint>

#include <openxr/openxr.h>

struct GAVAmbisonicAudio;

GAVAmbisonicAudio *gav_ambisonic_create(const char *sidecarPath);
void gav_ambisonic_destroy(GAVAmbisonicAudio *audio);

bool gav_ambisonic_schedule(GAVAmbisonicAudio *audio,
                            double mediaTimeSeconds,
                            uint64_t *hostTimeOut);
void gav_ambisonic_pause(GAVAmbisonicAudio *audio);
void gav_ambisonic_set_volume(GAVAmbisonicAudio *audio, float volume);

void gav_ambisonic_set_scene_basis(GAVAmbisonicAudio *audio,
                                   float rightX, float rightY, float rightZ,
                                   float upX, float upY, float upZ,
                                   float forwardX, float forwardY, float forwardZ);
void gav_ambisonic_set_head_orientation(GAVAmbisonicAudio *audio,
                                        const XrQuaternionf *orientation);
