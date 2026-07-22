/*
 * speech_bridge.m — ObjC implementation of speech_bridge.h.
 *
 * This is a direct behavioral port of the old speech_bridge.mm, which was
 * itself a port of SpeechEngine.swift: same engine (NSSpeechSynthesizer),
 * same delegate methods, same "one utterance at a time, superseded
 * requests get notified deterministically" behavior, same sender-identity
 * guard against stray callbacks from an already-superseded synthesizer.
 *
 * The one change from the .mm version: the event queue. That file used
 * std::queue guarded by std::mutex/std::condition_variable — the only
 * C++ in the whole project, and the reason this file needed an .mm
 * extension at all. Here that's replaced with NSMutableArray guarded by
 * an NSCondition, which gives the same "push from the delegate thread,
 * blocking-pull from the C HTTP thread" shape using nothing but
 * Foundation:
 *   - push_event  -> lock, append, [condition signal], unlock
 *   - next_event   -> lock, wait while empty && !done, pop front, unlock
 * NSCondition's -wait is the direct equivalent of
 * std::condition_variable::wait(lock, predicate) used in a loop.
 *
 * Everything else — the delegate, the single global synth, the
 * sender !== guard, voice resolution via NSSpeechSynthesizer.availableVoices
 * — is unchanged from the proven .mm logic.
 *
 * NOTE: unlike http_server.m/routes.m/voices.m/log.m, this file cannot
 * be compiled or tested outside macOS — there is no AppKit here. It's
 * carefully ported from the proven NSSpeechSynthesizer logic and the ObjC
 * method signatures are the same long-standing ones used throughout this
 * project's history, but treat this specific file as the one that most
 * needs a real build to confirm.
 *
 * This version replaces the C struct VerbatimSession with an @interface
 * and the C functions with class methods on SpeechBridge.
 */

#include "speech_bridge.h"

#import <AppKit/AppKit.h>
#include <string.h>

#include "log.h"

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
		LOG_TRACE(@"speech: session created (%p)", self);
	}
	return self;
}

- (NSString *)nextEvent
{
	[_queue.condition lock];
	LOG_TRACE(@"speech: nextEvent — waiting for event (queue=%lu, done=%d)",
	          (unsigned long) _queue.lines.count,
	          _queue.done);
	while (_queue.lines.count == 0 && !_queue.done) {
		[_queue.condition wait];
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

// ---------------------------------------------------------------------------
// SpeechBridge — global engine state
//
// Single utterance at a time, same as the Swift version's @MainActor
// serialisation.  An NSLock does the same job as the old std::mutex.
// ---------------------------------------------------------------------------

static NSLock                         *g_engine_lock     = nil;
static NSSpeechSynthesizer            *g_synth           = nil;
static id<NSSpeechSynthesizerDelegate> g_delegate        = nil;
static VerbatimSession                *g_current_session = nil;

static NSLock *engine_lock(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		g_engine_lock = [[NSLock alloc] init];
	});
	return g_engine_lock;
}

// ---------------------------------------------------------------------------
// Delegate — receives willSpeakWord / didFinishSpeaking callbacks
// ---------------------------------------------------------------------------

@interface VerbatimSpeechDelegate : NSObject <NSSpeechSynthesizerDelegate>
@end

@implementation VerbatimSpeechDelegate

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender
            willSpeakWord:(NSRange)characterRange
                 ofString:(NSString *)string
{
	[engine_lock() lock];
	if (sender != g_synth) {
		LOG_TRACE(@"speech: willSpeakWord IGNORED (stray callback from superseded synth)");
		[engine_lock() unlock];
		return; /* stray callback from a superseded synth — ignore, same
		         * guard as SpeechEngine.swift's `sender === synth` check */
	}
	LOG_TRACE(@"speech: willSpeakWord start=%ld length=%ld",
	          (long) characterRange.location,
	          (long) characterRange.length);

	NSString *json = [NSString stringWithFormat:@"{\"event\":\"word\",\"start\":%ld,\"length\":%ld}",
	                                            (long) characterRange.location,
	                                            (long) characterRange.length];
	VerbatimSession *session = g_current_session;
	[engine_lock() unlock];
	[session pushEvent:json terminal:NO];
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSpeaking
{
	[engine_lock() lock];
	if (sender != g_synth) {
		LOG_TRACE(@"speech: didFinishSpeaking IGNORED (stray callback from superseded synth)");
		[engine_lock() unlock];
		return;
	}
	LOG_INFO(@"speech: finished, completed=%@", finishedSpeaking ? @"true" : @"false");

	NSString        *json = [NSString stringWithFormat:@"{\"event\":\"finished\",\"completed\":%@}",
                                                finishedSpeaking ? @"true" : @"false"];
	VerbatimSession *session = g_current_session;

	g_synth           = nil;
	g_delegate        = nil;
	g_current_session = nil;
	[engine_lock() unlock];

	[session pushEvent:json terminal:YES];
}

@end

// ---------------------------------------------------------------------------
// Voice resolution
// ---------------------------------------------------------------------------

/* Resolves a human-friendly voice name (matched case-insensitively against
 * the same display names GET /voices returns) to the NSSpeechSynthesizer
 * voice identifier.  Uses NSVoiceName — the long-standing AppKit constant
 * for a voice's display name, predating Swift.  Returns nil if not found
 * (caller falls back to the default voice). */
static NSString *resolve_voice_name(NSString *name)
{
	if (name.length == 0)
		return nil;

	NSString            *target = [name lowercaseString];
	NSArray<NSString *> *voices = [NSSpeechSynthesizer availableVoices];

	LOG_TRACE(@"speech: resolving voice '%@' (%lu voices available)",
	          name,
	          (unsigned long) voices.count);

	for (NSString *voiceId in voices) {
		NSDictionary *attrs     = [NSSpeechSynthesizer attributesForVoice:voiceId];
		NSString     *voiceName = attrs[NSVoiceName];
		if (voiceName && [[voiceName lowercaseString] isEqualToString:target]) {
			LOG_TRACE(@"speech: resolved voice '%@' -> '%@'", name, voiceId);
			return voiceId;
		}
	}
	LOG_TRACE(@"speech: voice '%@' not found, using default", name);
	return nil;
}

// ---------------------------------------------------------------------------
// SpeechBridge — public API
// ---------------------------------------------------------------------------

@implementation SpeechBridge

+ (void)speakWithSession:(VerbatimSession *)session
                    text:(NSString *)text
                    rate:(float)rate
               voiceName:(NSString *)voiceName
{
	[engine_lock() lock];
	LOG_TRACE(@"speech: speak — locked engine");

	/* Interrupt + notify whatever was previously speaking — inlined here
	 * rather than calling -stop to avoid re-locking g_engine_lock (NSLock
	 * is not recursive, same as the old std::mutex). */
	VerbatimSession     *previous_session = g_current_session;
	NSSpeechSynthesizer *previous_synth   = g_synth;

	NSString *resolvedVoice = resolve_voice_name(voiceName);
	if (voiceName.length > 0 && resolvedVoice == nil) {
		LOG_WARN(@"speech: TTS-Voice '%@' not found on this system — using default voice",
		         voiceName);
	}

	LOG_INFO(@"speech: starting %lu chars, rate: %.0f wpm, voice: %@",
	         (unsigned long) text.length,
	         (double) rate,
	         voiceName.length > 0 ? voiceName : @"default");

	NSSpeechSynthesizer *synth = [[NSSpeechSynthesizer alloc] initWithVoice:resolvedVoice];
	if (!synth) {
		LOG_ERROR(@"speech: could not create NSSpeechSynthesizer");
		[engine_lock() unlock];
		if (previous_session) {
			[previous_session pushEvent:@"{\"event\":\"finished\",\"completed\":false}"
			                   terminal:YES];
		}
		if (previous_synth)
			[previous_synth stopSpeaking];
		[session
		    pushEvent:@"{\"event\":\"error\",\"message\":\"Could not create NSSpeechSynthesizer\"}"
		     terminal:YES];
		return;
	}

	LOG_TRACE(@"speech: NSSpeechSynthesizer created (%p)", synth);

	VerbatimSpeechDelegate *delegate = [[VerbatimSpeechDelegate alloc] init];
	synth.delegate                   = delegate;
	synth.rate                       = rate;

	g_synth           = synth;
	g_delegate        = delegate;
	g_current_session = session;

	[engine_lock() unlock];
	LOG_TRACE(@"speech: speak — unlocked engine");

	/* Now that the lock is released, notify the previous session and
	 * actually interrupt its synth — same ordering as the old .mm file
	 * (stopSpeaking happens before the new startSpeakingString call). */
	if (previous_session) {
		LOG_TRACE(@"speech: notifying previous session of interruption");
		[previous_session pushEvent:@"{\"event\":\"finished\",\"completed\":false}" terminal:YES];
	}
	if (previous_synth) {
		LOG_TRACE(@"speech: stopping previous synthesizer");
		[previous_synth stopSpeaking];
	}

	[session pushEvent:@"{\"event\":\"started\"}" terminal:NO];

	LOG_TRACE(@"speech: calling startSpeakingString");
	BOOL ok = [synth startSpeakingString:text];
	if (!ok) {
		LOG_ERROR(@"speech: startSpeakingString returned NO");
		[session pushEvent:@"{\"event\":\"error\",\"message\":\"startSpeaking returned false\"}"
		          terminal:YES];

		[engine_lock() lock];
		if (g_synth == synth) {
			g_synth           = nil;
			g_delegate        = nil;
			g_current_session = nil;
		}
		[engine_lock() unlock];
	}
	LOG_TRACE(@"speech: speak — done");
}

+ (void)stop
{
	[engine_lock() lock];
	LOG_TRACE(@"speech: stop — locked engine");
	if (!g_current_session) {
		LOG_DEBUG(@"speech: stop() called but nothing is speaking — nothing to do");
		[engine_lock() unlock];
		return;
	}
	LOG_INFO(@"speech: stopping current utterance");

	VerbatimSession     *session = g_current_session;
	NSSpeechSynthesizer *synth   = g_synth;

	g_synth           = nil;
	g_delegate        = nil;
	g_current_session = nil;
	[engine_lock() unlock];
	LOG_TRACE(@"speech: stop — unlocked engine");

	[session pushEvent:@"{\"event\":\"finished\",\"completed\":false}" terminal:YES];
	[synth stopSpeaking];
	LOG_TRACE(@"speech: stop — done");
}

+ (BOOL)isSpeaking
{
	[engine_lock() lock];
	BOOL speaking = g_current_session != nil;
	[engine_lock() unlock];
	LOG_TRACE(@"speech: isSpeaking = %d", speaking);
	return speaking;
}

@end
