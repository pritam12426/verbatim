#ifndef _VERBATIM_SPEECH_BRIDGE_H_
#define _VERBATIM_SPEECH_BRIDGE_H_


#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// VerbatimSession — one per POST / request
//
// Owns a queue of pending NDJSON event lines pushed by the speech
// engine's delegate callbacks and pulled (blocking) by the HTTP thread
// via -nextEvent.
// ---------------------------------------------------------------------------

@interface VerbatimSession : NSObject
- (instancetype)init;

// Blocks until the next NDJSON event line is available, then returns it.
// Returns nil once the stream has ended (after the terminal
// finished/stopped/error event has already been delivered).
- (nullable NSString *)nextEvent;
@end

// ---------------------------------------------------------------------------
// SpeechBridge — C-level interface to NSSpeechSynthesizer
//
// All methods are class-level: the engine is a single global
// NSSpeechSynthesizer guarded by a lock, same as the Swift version's
// @MainActor serialisation.
// ---------------------------------------------------------------------------

@interface SpeechBridge : NSObject

// Starts speaking `text`, interrupting whatever was previously speaking.
// voiceName may be nil (use the system default voice).  Events arrive
// via [session nextEvent].
+ (void)speakWithSession:(VerbatimSession *)session
                    text:(NSString *)text
                    rate:(float)rate
               voiceName:(nullable NSString *)voiceName;

// Stops whatever is currently speaking, if anything.
+ (void)stop;

// Non-zero if the engine is currently speaking.
+ (BOOL)isSpeaking;

@end

NS_ASSUME_NONNULL_END


#endif  // _VERBATIM_SPEECH_BRIDGE_H_
