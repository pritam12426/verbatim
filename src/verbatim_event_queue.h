/*
 * verbatim_event_queue.h — per-request event queue
 *
 * Owns a queue of pending NDJSON event lines pushed by the speech
 * engine's delegate callbacks and pulled (blocking) by the HTTP thread
 * via -nextEvent.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VerbatimSession : NSObject
- (instancetype)init;

// Blocks until the next NDJSON event line is available, then returns it.
// Returns nil once the stream has ended (after the terminal
// finished/stopped/error event has already been delivered).
- (nullable NSString *)nextEvent;

// Pushes an event line into the queue.  If terminal is YES, signals
// that no more events will follow.
- (void)pushEvent:(NSString *)line terminal:(BOOL)terminal;
@end

NS_ASSUME_NONNULL_END
