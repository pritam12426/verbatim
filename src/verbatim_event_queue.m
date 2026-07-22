/*
 * verbatim_event_queue.m — thread-safe producer/consumer event queue.
 *
 * Generic streaming primitive with zero speech/AppKit dependency.
 * VerbatimEventQueue is the internal queue; VerbatimSession is the
 * public wrapper exposing -nextEvent (blocking pull) and -pushEvent:terminal:
 * (push + signal).
 *
 * Thread safety model:
 *   NSCondition provides both mutual exclusion (lock/unlock) and
 *   signalling (signal/wait).  This is the ObjC equivalent of
 *   pthread_cond_t + pthread_mutex_t, but with a cleaner API.
 *
 *   - pushEvent:terminal: acquires the lock, appends to the array,
 *     signals one waiting thread, and releases the lock.
 *   - nextEvent acquires the lock, waits while the queue is empty
 *     and not done, pops the first element, and releases the lock.
 *
 * Why not dispatch_queue / GCD?
 *   - NSCondition gives us blocking-pull semantics natively.
 *   - GCD's dispatch_semaphore would require a separate data structure
 *     for the queue itself.
 *   - NSCondition is the standard ObjC primitive for producer/consumer.
 *
 * No AppKit dependency:
 *   This file imports only Foundation — no AppKit.  This makes it
 *   independently testable on any platform, and keeps the speech
 *   engine's queue logic separate from the speech engine itself.
 */

#import "verbatim_event_queue.h"

#import "log.h"

// ---------------------------------------------------------------------------
// VerbatimEventQueue — internal, owns the push/pull queue
// ---------------------------------------------------------------------------

// The internal queue object.  Not exposed in the header — only
// VerbatimSession uses it.
@interface                                               VerbatimEventQueue : NSObject
@property(nonatomic, strong) NSCondition                *condition;  // Mutex + signalling
@property(nonatomic, strong) NSMutableArray<NSString *> *lines;      // The event queue
@property(nonatomic) BOOL                                done;       // Stream ended flag
@end

@implementation VerbatimEventQueue

// Initialise the queue with an empty array and a new NSCondition.
- (instancetype)init
{
	self = [super init];
	if (self) {
		_condition = [[NSCondition alloc] init];
		_lines     = [NSMutableArray array];
		_done      = NO;
		LOG_TRACE(@"speech: event queue initialized");
	}
	return self;
}

@end

// ---------------------------------------------------------------------------
// VerbatimSession — public @implementation
// ---------------------------------------------------------------------------

@implementation VerbatimSession {
	VerbatimEventQueue *_queue;  // The internal queue (ivar, not a property)
}

// Create a new session with an empty event queue.
- (instancetype)init
{
	self = [super init];
	if (self) {
		_queue = [[VerbatimEventQueue alloc] init];
		LOG_TRACE(@"speech: session created (%p)", (void *) self);
	}
	return self;
}

// ── nextEvent ────────────────────────────────────────────────────────────────
// Blocks until the next NDJSON event line is available, then returns it.
//
// Returns nil once the stream has ended (after the terminal event
// has been consumed).
//
// Thread safety:
//   1. Acquire the condition lock
//   2. Wait while queue is empty AND not done
//   3. If an event is available, pop it and return
//   4. If done and queue is empty, return nil
//
// Timeout:
//   Uses waitUntilDate: instead of wait to prevent indefinite blocking
//   if the speech engine stalls (e.g. NSSpeechSynthesizer is deallocated
//   without sending a finished event).  30 seconds is generous enough
//   for any reasonable utterance.
- (NSString *)nextEvent
{
	[_queue.condition lock];
	LOG_TRACE(@"speech: nextEvent — waiting for event (queue=%lu, done=%d)",
	          (unsigned long) _queue.lines.count,
	          _queue.done);

	// Wait up to 30 seconds for an event
	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
	while (_queue.lines.count == 0 && !_queue.done) {
		if (![_queue.condition waitUntilDate:deadline]) {
			// Timed out — return nil to prevent indefinite blocking
			LOG_WARN(@"speech: nextEvent — timed out after 30s");
			[_queue.condition unlock];
			return nil;
		}
	}

	// Check if there's an event to return
	if (_queue.lines.count > 0) {
		// Pop the first event from the queue (FIFO)
		NSString *line = _queue.lines[0];
		[_queue.lines removeObjectAtIndex:0];
		[_queue.condition unlock];
		LOG_TRACE(@"speech: nextEvent — got event (remaining=%lu)",
		          (unsigned long) _queue.lines.count);
		return line;
	}

	// Queue is empty and done — stream has ended
	[_queue.condition unlock];
	LOG_TRACE(@"speech: nextEvent — stream ended");
	return nil;
}

// ── pushEvent:terminal: ──────────────────────────────────────────────────────
// Pushes an event line into the queue.
//
// If terminal is YES, signals that no more events will follow.
// After a terminal event, done = YES, and subsequent nextEvent
// calls will return nil once the queue is drained.
//
// Thread safety:
//   1. Acquire the condition lock
//   2. Append the event line
//   3. If terminal, set done = YES
//   4. Signal one waiting thread (the HTTP thread in nextEvent)
//   5. Release the lock
- (void)pushEvent:(NSString *)line terminal:(BOOL)terminal
{
	[_queue.condition lock];
	[_queue.lines addObject:line];
	if (terminal)
		_queue.done = YES;
	[_queue.condition signal];  // Wake up the waiting nextEvent call
	[_queue.condition unlock];
	LOG_TRACE(@"speech: pushEvent — queued (terminal=%d, queue=%lu)",
	          terminal,
	          (unsigned long) _queue.lines.count);
}

@end
