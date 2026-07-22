/*
 * speech_bridge.h — ObjC interface to NSSpeechSynthesizer.
 *
 * This is the speech engine that powers verbatimd.  It wraps
 * NSSpeechSynthesizer (macOS's built-in TTS engine) and provides
 * a simple class-level API:
 *
 *   +speakWithSession:text:rate:voiceName: — start speaking
 *   +stop                                  — stop speaking
 *   +isSpeaking                           — check if speaking
 *
 * Threading model:
 *   All methods are class-level (no instances created).
 *   A single global NSSpeechSynthesizer is guarded by an NSLock,
 *   ensuring only one utterance is active at a time.
 *
 *   This is the same serialisation guarantee as the Swift version's
 *   @MainActor, but implemented with an explicit lock instead of
 *   Swift Concurrency's runtime.
 *
 * Event delivery:
 *   Per-word timing events are delivered via VerbatimSession's
 *   pushEvent:terminal: method, called from the speech delegate's
 *   willSpeakWord:ofString: callback.  The HTTP thread pulls these
 *   events via [session nextEvent] (blocking).
 *
 * Voice resolution:
 *   The client can specify a voice name (e.g. "Albert") via the
 *   TTS-Voice header.  +resolveVoiceName: maps this to an
 *   NSSpeechSynthesizer voice identifier by looking up available
 *   voices and comparing display names case-insensitively.
 */

#import <Foundation/Foundation.h>

#import "verbatim_event_queue.h"

NS_ASSUME_NONNULL_BEGIN

// SpeechBridge — ObjC interface to NSSpeechSynthesizer.
// All methods are class-level (no instances created).
@interface SpeechBridge : NSObject

// Starts speaking `text`, interrupting whatever was previously speaking.
//
// Parameters:
//   session   — the VerbatimSession that will receive word/finished events
//   text      — the text to speak (UTF-8 string)
//   rate      — speaking rate in words per minute (e.g. 175)
//   voiceName — display name of the voice (e.g. "Albert"), or nil
//               for the system default voice
//
// If a previous utterance is active, it is interrupted and its
// session receives a {"event":"finished","completed":false} event.
//
// Events are pushed into the session's queue as they arrive from
// the speech delegate.  The HTTP thread pulls them via [session nextEvent].
+ (void)speakWithSession:(VerbatimSession *)session
                    text:(NSString *)text
                    rate:(float)rate
               voiceName:(nullable NSString *)voiceName;

// Stops whatever is currently speaking, if anything.
// The active session receives a {"event":"finished","completed":false}
// event, and the synthesizer is released.
+ (void)stop;

// Returns YES if the engine is currently speaking.
// Thread-safe (acquires the engine lock).
+ (BOOL)isSpeaking;

@end

NS_ASSUME_NONNULL_END
