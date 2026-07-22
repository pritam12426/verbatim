/*
 * voices.h — voice listing, backing GET /voices.
 *
 * Voice *resolution* (matching a TTS-Voice header value to the identifier
 * NSSpeechSynthesizer actually needs) lives in speech_bridge.m instead,
 * since it needs NSSpeechSynthesizer.availableVoices — the native API,
 * not `say`'s text output. This module only needs to shell out and parse,
 * so it stays close to plain C with no AppKit dependency.
 */

#ifndef VERBATIM_VOICES_H
#define VERBATIM_VOICES_H

#include <stddef.h>

typedef struct {
	char name[128];
	char language[32];
} VoiceInfo;

/* Shells out to `say -v '?'` and parses its output (format verified stable
 * — see voices.m). Returns a malloc'd array of *count entries; caller must
 * free() it. Returns NULL and sets *count = 0 on failure. Cached after the
 * first successful call for the process lifetime, same as the Swift
 * version. */
VoiceInfo *voices_list(size_t *count);

#endif /* VERBATIM_VOICES_H */
