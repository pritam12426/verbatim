/*
 * verbatim_event_queue.m — thread-safe producer/consumer event queue.
 *
 * Generic streaming primitive with zero speech/AppKit dependency.
 * VerbatimEventQueue is the internal queue; VerbatimSession is the
 * public wrapper exposing -nextEvent (blocking pull) and -pushEvent:terminal:
 * (push + signal).
 */

#import "verbatim_event_queue.h"

#import "log.h"

// ---------------------------------------------------------------------------
// VerbatimEventQueue — internal, owns the push/pull queue
// ---------------------------------------------------------------------------

@interface                                               VerbatimEventQueue : NSObject
@property(nonatomic, strong) NSCondition                *condition;
@property(nonatomic, strong) NSMutableArray<NSString *> *lines;
@property(nonatomic) BOOL                                done;
@end

@implementation VerbatimEventQueue
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
	VerbatimEventQueue *_queue;
}

- (instancetype)init
{
	self = [super init];
	if (self) {
		_queue = [[VerbatimEventQueue alloc] init];
		LOG_TRACE(@"speech: session created (%p)", (void *) self);
	}
	return self;
}

- (NSString *)nextEvent
{
	[_queue.condition lock];
	LOG_TRACE(@"speech: nextEvent — waiting for event (queue=%lu, done=%d)",
	          (unsigned long) _queue.lines.count,
	          _queue.done);

	NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
	while (_queue.lines.count == 0 && !_queue.done) {
		if (![_queue.condition waitUntilDate:deadline]) {
			LOG_WARN(@"speech: nextEvent — timed out after 30s");
			[_queue.condition unlock];
			return nil;
		}
	}

	if (_queue.lines.count > 0) {
		NSString *line = _queue.lines[0];
		[_queue.lines removeObjectAtIndex:0];
		[_queue.condition unlock];
		LOG_TRACE(@"speech: nextEvent — got event (remaining=%lu)",
		          (unsigned long) _queue.lines.count);
		return line;
	}

	[_queue.condition unlock];
	LOG_TRACE(@"speech: nextEvent — stream ended");
	return nil;
}

- (void)pushEvent:(NSString *)line terminal:(BOOL)terminal
{
	[_queue.condition lock];
	[_queue.lines addObject:line];
	if (terminal)
		_queue.done = YES;
	[_queue.condition signal];
	[_queue.condition unlock];
	LOG_TRACE(@"speech: pushEvent — queued (terminal=%d, queue=%lu)",
	          terminal,
	          (unsigned long) _queue.lines.count);
}

@end
