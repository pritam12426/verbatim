/*
 * verbatim_event_queue.h — per-request event queue.
 *
 * Owns a queue of pending NDJSON event lines pushed by the speech
 * engine's delegate callbacks and pulled (blocking) by the HTTP thread
 * via -nextEvent.
 *
 * This is the thread-safe bridge between the speech engine (which
 * pushes events from the main thread's run loop) and the HTTP
 * response (which pulls events from a connection thread).
 *
 * Thread safety:
 *   - NSCondition provides both mutual exclusion and signalling.
 *   - pushEvent:terminal: acquires the lock, appends to the array,
 *     signals the condition, and releases the lock.
 *   - nextEvent acquires the lock, waits while the queue is empty
 *     and not done, pops the first element, and releases the lock.
 *   - A 30-second timeout prevents indefinite blocking if the
 *     speech engine stalls or the synthesizer is deallocated
 *     without sending a finished event.
 *
 * Stream lifecycle:
 *   1. Session is created, queue is empty, done = NO.
 *   2. Speech starts: "started" event is pushed (not terminal).
 *   3. Words are spoken: "word" events are pushed (not terminal).
 *   4. Speech finishes: "finished" event is pushed (terminal = YES).
 *      This sets done = YES, signalling that no more events will follow.
 *   5. nextEvent returns nil after the terminal event has been consumed.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// VerbatimSession — one per POST / request.
// Owns an internal VerbatimEventQueue and exposes the public API.
@interface VerbatimSession : NSObject

- (instancetype)init;

// Blocks until the next NDJSON event line is available, then returns it.
//
// Returns nil once the stream has ended (after the terminal
// finished/stopped/error event has already been delivered).
//
// Thread-safe: can be called from the HTTP connection thread while
// the speech delegate pushes events from the main thread.
//
// Timeout: returns nil after 30 seconds if no event arrives,
// preventing indefinite blocking on stalled speech.
- (nullable NSString *)nextEvent;

// Pushes an event line into the queue.
//
// If terminal is YES, signals that no more events will follow.
// After a terminal event, subsequent nextEvent calls will return
// nil once the queue is drained.
//
// Thread-safe: can be called from the speech delegate's callback
// while the HTTP thread is blocked in nextEvent.
- (void)pushEvent:(NSString *)line terminal:(BOOL)terminal;

@end

NS_ASSUME_NONNULL_END
