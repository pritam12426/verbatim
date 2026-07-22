/*
 * speech_bridge.m — plain Objective-C implementation of speech_bridge.h.
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
 * NOTE: unlike http_server.m/routes.m/voices.m/log.m (all compiled and
 * exercised end-to-end against curl on Linux via a mock backend during
 * development), this file cannot be compiled or tested outside macOS —
 * there is no AppKit here. It's carefully ported from the proven
 * NSSpeechSynthesizer logic and the ObjC method signatures are the same
 * long-standing ones used throughout this project's history, but treat
 * this specific file as the one that most needs a real build to confirm.
 */

#import <AppKit/AppKit.h>

#include <string.h>

#include "log.h"
#include "speech_bridge.h"

/* ---- session: the queue a session's C-side consumer pulls from ---- */

@interface VerbatimEventQueue : NSObject
@property (nonatomic, strong) NSCondition *condition;
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
@property (nonatomic) BOOL done;
@end

@implementation VerbatimEventQueue
- (instancetype)init {
	self = [super init];
	if (self) {
		_condition = [[NSCondition alloc] init];
		_lines = [NSMutableArray array];
		_done = NO;
	}
	return self;
}
@end

/* VerbatimSession is declared (but left opaque) in speech_bridge.h; the
 * real definition lives here, same as the old .mm file's struct did.
 *
 * `queue` is a `void *` rather than a plain `VerbatimEventQueue *`
 * because ARC forbids owning Objective-C pointers as members of a C
 * struct — there's no way for ARC to know when a malloc'd struct is
 * freed, so it can't manage the retain/release for us. Instead the
 * pointer is manually retained via CFBridgingRetain() at creation and
 * released via CFBridgingRelease() at destruction — the standard idiom
 * for handing an ARC object across a plain-C-lifetime boundary — and
 * bridged back to an ObjC reference (non-owning, since we already own it
 * manually) wherever it's used. */
struct VerbatimSession {
	void *queue;
};

VerbatimSession *verbatim_session_create(void) {
	VerbatimSession *session = (VerbatimSession *)malloc(sizeof(VerbatimSession));
	if (!session) return NULL;
	VerbatimEventQueue *queue = [[VerbatimEventQueue alloc] init];
	session->queue = (void *)CFBridgingRetain(queue); /* +1, ours to release */
	return session;
}

void verbatim_session_destroy(VerbatimSession *session) {
	if (!session) return;
	CFBridgingRelease(session->queue); /* balances the +1 from create() */
	free(session);
}

static void push_event(VerbatimSession *session, NSString *line, BOOL terminal) {
	if (!session) return;
	VerbatimEventQueue *queue = (__bridge VerbatimEventQueue *)session->queue;
	[queue.condition lock];
	[queue.lines addObject:line];
	if (terminal) queue.done = YES;
	[queue.condition signal];
	[queue.condition unlock];
}

size_t verbatim_next_event(VerbatimSession *session, char *buf, size_t buflen) {
	VerbatimEventQueue *queue = (__bridge VerbatimEventQueue *)session->queue;
	[queue.condition lock];
	while (queue.lines.count == 0 && !queue.done) {
		[queue.condition wait];
	}

	if (queue.lines.count > 0) {
		NSString *line = queue.lines[0];
		[queue.lines removeObjectAtIndex:0];
		[queue.condition unlock];

		const char *cstr = [line UTF8String];
		size_t n = strlen(cstr);
		if (n >= buflen) n = buflen - 1;
		memcpy(buf, cstr, n);
		buf[n] = '\0';
		return n;
	}

	[queue.condition unlock];
	return 0; /* done, nothing left */
}

/* ---- global engine state (single utterance at a time, same as before) ---- */
/* Guarded by g_engine_lock throughout — this mirrors @MainActor's job of
 * serializing access in the Swift version. An NSLock does the same job
 * here as the old std::mutex did. */

static NSLock *g_engine_lock = nil;
static NSSpeechSynthesizer *g_synth = nil;
static id<NSSpeechSynthesizerDelegate> g_delegate = nil;
static VerbatimSession *g_current_session = NULL;

static NSLock *engine_lock(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		g_engine_lock = [[NSLock alloc] init];
	});
	return g_engine_lock;
}

@interface VerbatimSpeechDelegate : NSObject <NSSpeechSynthesizerDelegate>
@end

@implementation VerbatimSpeechDelegate

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender
             willSpeakWord:(NSRange)characterRange
                  ofString:(NSString *)string {
	[engine_lock() lock];
	if (sender != g_synth) {
		LOG_TRACE(@"speech: willSpeakWord IGNORED (stray callback from superseded synth)");
		[engine_lock() unlock];
		return; /* stray callback from a superseded synth — ignore, same
		         * guard as SpeechEngine.swift's `sender === synth` check */
	}
	LOG_TRACE(@"speech: willSpeakWord start=%ld length=%ld", (long)characterRange.location,
	          (long)characterRange.length);

	NSString *json = [NSString stringWithFormat:@"{\"event\":\"word\",\"start\":%ld,\"length\":%ld}",
	                                             (long)characterRange.location,
	                                             (long)characterRange.length];
	VerbatimSession *session = g_current_session;
	[engine_lock() unlock];
	push_event(session, json, NO);
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender
        didFinishSpeaking:(BOOL)finishedSpeaking {
	[engine_lock() lock];
	if (sender != g_synth) {
		LOG_TRACE(@"speech: didFinishSpeaking IGNORED (stray callback from superseded synth)");
		[engine_lock() unlock];
		return;
	}
	LOG_INFO(@"speech: finished, completed=%@", finishedSpeaking ? @"true" : @"false");

	NSString *json = [NSString stringWithFormat:@"{\"event\":\"finished\",\"completed\":%@}",
	                                             finishedSpeaking ? @"true" : @"false"];
	VerbatimSession *session = g_current_session;

	g_synth = nil;
	g_delegate = nil;
	g_current_session = NULL;
	[engine_lock() unlock];

	push_event(session, json, YES);
}

@end

/* Resolves a human-friendly voice name (matched case-insensitively against
 * the same display names GET /voices returns) to the NSSpeechSynthesizer
 * voice identifier. Uses NSVoiceName — the long-standing AppKit constant
 * for a voice's display name, predating Swift. Returns nil if not found
 * (caller falls back to the default voice). */
static NSString *resolve_voice_name(const char *name) {
	if (!name || name[0] == '\0') return nil;

	NSString *target = [[NSString stringWithUTF8String:name] lowercaseString];
	NSArray<NSString *> *voices = [NSSpeechSynthesizer availableVoices];

	for (NSString *voiceId in voices) {
		NSDictionary *attrs = [NSSpeechSynthesizer attributesForVoice:voiceId];
		NSString *voiceName = attrs[NSVoiceName];
		if (voiceName && [[voiceName lowercaseString] isEqualToString:target]) {
			return voiceId;
		}
	}
	return nil;
}

/* ---- public C ABI ---- */

void verbatim_speak(VerbatimSession *session, const char *text, float rate,
                     const char *voice_name) {
	[engine_lock() lock];

	/* Interrupt + notify whatever was previously speaking — inlined here
	 * rather than calling verbatim_stop() to avoid re-locking
	 * g_engine_lock (NSLock is not recursive, same as the old std::mutex). */
	VerbatimSession *previous_session = g_current_session;
	NSSpeechSynthesizer *previous_synth = g_synth;

	NSString *resolvedVoice = resolve_voice_name(voice_name);
	if (voice_name && voice_name[0] != '\0' && resolvedVoice == nil) {
		LOG_WARN(@"speech: TTS-Voice '%s' not found on this system — using default voice",
		         voice_name);
	}

	LOG_INFO(@"speech: starting %zu chars, rate: %.0f wpm, voice: %s", strlen(text), (double)rate,
	         voice_name && voice_name[0] ? voice_name : "default");

	NSSpeechSynthesizer *synth = [[NSSpeechSynthesizer alloc] initWithVoice:resolvedVoice];
	if (!synth) {
		LOG_ERROR(@"speech: could not create NSSpeechSynthesizer");
		[engine_lock() unlock];
		if (previous_session) {
			push_event(previous_session, @"{\"event\":\"finished\",\"completed\":false}", YES);
		}
		if (previous_synth) [previous_synth stopSpeaking];
		push_event(session, @"{\"event\":\"error\",\"message\":\"Could not create NSSpeechSynthesizer\"}",
		           YES);
		return;
	}

	VerbatimSpeechDelegate *delegate = [[VerbatimSpeechDelegate alloc] init];
	synth.delegate = delegate;
	synth.rate = rate;

	g_synth = synth;
	g_delegate = delegate;
	g_current_session = session;

	[engine_lock() unlock];

	/* Now that the lock is released, notify the previous session and
	 * actually interrupt its synth — same ordering as the old .mm file
	 * (stopSpeaking happens before the new startSpeakingString call). */
	if (previous_session) {
		push_event(previous_session, @"{\"event\":\"finished\",\"completed\":false}", YES);
	}
	if (previous_synth) {
		[previous_synth stopSpeaking];
	}

	push_event(session, @"{\"event\":\"started\"}", NO);

	NSString *nsText = [NSString stringWithUTF8String:text];
	BOOL ok = [synth startSpeakingString:nsText];
	if (!ok) {
		LOG_ERROR(@"speech: startSpeakingString returned NO");
		push_event(session, @"{\"event\":\"error\",\"message\":\"startSpeaking returned false\"}", YES);

		[engine_lock() lock];
		if (g_synth == synth) {
			g_synth = nil;
			g_delegate = nil;
			g_current_session = NULL;
		}
		[engine_lock() unlock];
	}
}

void verbatim_stop(void) {
	[engine_lock() lock];
	if (!g_current_session) {
		LOG_DEBUG(@"speech: stop() called but nothing is speaking — nothing to do");
		[engine_lock() unlock];
		return;
	}
	LOG_INFO(@"speech: stopping current utterance");

	VerbatimSession *session = g_current_session;
	NSSpeechSynthesizer *synth = g_synth;

	g_synth = nil;
	g_delegate = nil;
	g_current_session = NULL;
	[engine_lock() unlock];

	push_event(session, @"{\"event\":\"finished\",\"completed\":false}", YES);
	[synth stopSpeaking];
}

int verbatim_is_speaking(void) {
	[engine_lock() lock];
	int speaking = g_current_session != NULL;
	[engine_lock() unlock];
	return speaking;
}
