/*
 * speech_bridge.h — C interface to the speech engine.
 *
 * Real implementation: speech_bridge.m (plain Objective-C, NSSpeechSynthesizer).
 * This header is the entire contract the C HTTP layer depends on — it
 * never touches AppKit directly.
 *
 * The old version of this header guarded its declarations with
 * `extern "C" { ... }` because the implementation lived in a .mm
 * (Objective-C++) file and needed C linkage to be callable from the
 * plain-C http_server.c/routes.c. Now that speech_bridge.m has no C++ in
 * it, that guard is gone: Objective-C functions already use C calling
 * convention, so http_server.m/routes.m can call these directly.
 */

#ifndef VERBATIM_SPEECH_BRIDGE_H
#define VERBATIM_SPEECH_BRIDGE_H

#include <stddef.h>

typedef struct VerbatimSession VerbatimSession;

/* One session per POST / request. Owns its own queue of pending NDJSON
 * event lines — see verbatim_next_event(). */
VerbatimSession *verbatim_session_create(void);
void verbatim_session_destroy(VerbatimSession *session);

/* Starts speaking `text` on this session, interrupting whatever the
 * (single, global) engine was previously speaking — same "one utterance
 * at a time" behaviour as the Swift version. voice_name may be NULL (use
 * the system default voice). Returns immediately; events arrive via
 * verbatim_next_event(). */
void verbatim_speak(VerbatimSession *session, const char *text, float rate, const char *voice_name);

/* Stops whatever is currently speaking, if anything. */
void verbatim_stop(void);

/* Non-zero if the engine is currently speaking. */
int verbatim_is_speaking(void);

/* Blocks until the next NDJSON event line for this session is available,
 * writes it (NUL-terminated) into buf, and returns its length. Returns 0
 * once the session's stream has ended (after the terminal
 * finished/stopped/error event has already been delivered) — the caller
 * should stop reading at that point. */
size_t verbatim_next_event(VerbatimSession *session, char *buf, size_t buflen);

#endif /* VERBATIM_SPEECH_BRIDGE_H */
