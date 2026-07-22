/*
 * speech_bridge.m — ObjC implementation of speech_bridge.h.
 *
 * Global engine state (single NSSpeechSynthesizer guarded by NSLock),
 * delegate callbacks, voice resolution, and the public SpeechBridge API.
 *
 * The event queue (VerbatimSession / VerbatimEventQueue) lives in its
 * own file with zero AppKit dependency.
 */

#import "speech_bridge.h"

#import <AppKit/AppKit.h>

#import "log.h"
#import "verbatim_event_queue.h"

// ---------------------------------------------------------------------------
// SpeechBridge — global engine state
// ---------------------------------------------------------------------------

static NSLock                         *g_engine_lock     = nil;
static NSSpeechSynthesizer            *g_synth           = nil;
static id<NSSpeechSynthesizerDelegate> g_delegate        = nil;
static VerbatimSession                *g_current_session = nil;

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
	[g_engine_lock lock];
	if (sender != g_synth) {
		LOG_TRACE(@"speech: willSpeakWord IGNORED (stray callback from superseded synth)");
		[g_engine_lock unlock];
		return;
	}
	LOG_TRACE(@"speech: willSpeakWord start=%ld length=%ld",
	          (long) characterRange.location,
	          (long) characterRange.length);

	NSString *json = [NSString stringWithFormat:@"{\"event\":\"word\",\"start\":%ld,\"length\":%ld}",
	                                            (long) characterRange.location,
	                                            (long) characterRange.length];
	VerbatimSession *session = g_current_session;
	[g_engine_lock unlock];
	[session pushEvent:json terminal:NO];
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSpeaking
{
	[g_engine_lock lock];
	if (sender != g_synth) {
		LOG_TRACE(@"speech: didFinishSpeaking IGNORED (stray callback from superseded synth)");
		[g_engine_lock unlock];
		return;
	}
	LOG_INFO(@"speech: finished, completed=%@", finishedSpeaking ? @"true" : @"false");

	NSString        *json = [NSString stringWithFormat:@"{\"event\":\"finished\",\"completed\":%@}",
                                                finishedSpeaking ? @"true" : @"false"];
	VerbatimSession *session = g_current_session;

	g_synth           = nil;
	g_delegate        = nil;
	g_current_session = nil;
	[g_engine_lock unlock];

	[session pushEvent:json terminal:YES];
}

@end

// ---------------------------------------------------------------------------
// SpeechBridge — public API
// ---------------------------------------------------------------------------

@implementation SpeechBridge

+ (void)initialize
{
	if (self == [SpeechBridge class]) {
		g_engine_lock = [[NSLock alloc] init];
	}
}

+ (NSString *)resolveVoiceName:(NSString *)name
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

+ (void)speakWithSession:(VerbatimSession *)session
                    text:(NSString *)text
                    rate:(float)rate
               voiceName:(NSString *)voiceName
{
	[g_engine_lock lock];
	LOG_TRACE(@"speech: speak — locked engine");

	VerbatimSession     *previous_session = g_current_session;
	NSSpeechSynthesizer *previous_synth   = g_synth;

	NSString *resolvedVoice = [self resolveVoiceName:voiceName];
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
		[g_engine_lock unlock];
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

	LOG_TRACE(@"speech: NSSpeechSynthesizer created");

	VerbatimSpeechDelegate *delegate = [[VerbatimSpeechDelegate alloc] init];
	synth.delegate                   = delegate;
	synth.rate                       = rate;

	g_synth           = synth;
	g_delegate        = delegate;
	g_current_session = session;

	[g_engine_lock unlock];
	LOG_TRACE(@"speech: speak — unlocked engine");

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

		[g_engine_lock lock];
		if (g_synth == synth) {
			g_synth           = nil;
			g_delegate        = nil;
			g_current_session = nil;
		}
		[g_engine_lock unlock];
	}
	LOG_TRACE(@"speech: speak — done");
}

+ (void)stop
{
	[g_engine_lock lock];
	LOG_TRACE(@"speech: stop — locked engine");
	if (!g_current_session) {
		LOG_DEBUG(@"speech: stop() called but nothing is speaking — nothing to do");
		[g_engine_lock unlock];
		return;
	}
	LOG_INFO(@"speech: stopping current utterance");

	VerbatimSession     *session = g_current_session;
	NSSpeechSynthesizer *synth   = g_synth;

	g_synth           = nil;
	g_delegate        = nil;
	g_current_session = nil;
	[g_engine_lock unlock];
	LOG_TRACE(@"speech: stop — unlocked engine");

	[session pushEvent:@"{\"event\":\"finished\",\"completed\":false}" terminal:YES];
	[synth stopSpeaking];
	LOG_TRACE(@"speech: stop — done");
}

+ (BOOL)isSpeaking
{
	[g_engine_lock lock];
	BOOL speaking = g_current_session != nil;
	[g_engine_lock unlock];
	LOG_TRACE(@"speech: isSpeaking = %d", speaking);
	return speaking;
}

@end
