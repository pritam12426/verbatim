/*
 * speech_bridge.h — ObjC interface to NSSpeechSynthesizer
 *
 * All methods are class-level: the engine is a single global
 * NSSpeechSynthesizer guarded by a lock, same as the Swift version's
 * @MainActor serialisation.
 */

#import <Foundation/Foundation.h>

#import "verbatim_event_queue.h"

NS_ASSUME_NONNULL_BEGIN

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
