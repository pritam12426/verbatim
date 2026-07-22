/*
 * speech_bridge.m — ObjC implementation of speech_bridge.h.
 *
 * Global engine state (single NSSpeechSynthesizer guarded by NSLock),
 * delegate callbacks, voice resolution, and the public SpeechBridge API.
 *
 * Architecture:
 *   - A single global NSSpeechSynthesizer (g_synth) handles one
 *     utterance at a time.  When speakWithSession: is called, any
 *     active synthesizer is interrupted and its session notified.
 *   - An NSLock (g_engine_lock) serialises access to the global state,
 *     preventing race conditions between the HTTP thread (which calls
 *     speak/stop) and the speech delegate callbacks (which push events).
 *   - The delegate (VerbatimSpeechDelegate) receives willSpeakWord:
 *     and didFinishSpeaking: callbacks from NSSpeechSynthesizer and
 *     pushes NDJSON event lines into the VerbatimSession's queue.
 *
 * Thread model:
 *   - Main thread: runs CFRunLoopRun() — NSSpeechSynthesizer delegate
 *     callbacks are delivered on this thread.
 *   - HTTP thread: calls speakWithSession: and stop, which acquire
 *     g_engine_lock, modify global state, and release the lock.
 *   - Connection thread: calls [session nextEvent] (blocking pull)
 *     to consume events pushed by the delegate.
 *
 * Sender identity guard:
 *   When a delegate callback arrives, we check `sender != g_synth`
 *   to ignore stray callbacks from a synthesizer that was superseded
 *   by a newer speak request.  This is the same guard as the Swift
 *   version's `sender === synth` check.
 *
 * The event queue (VerbatimSession / VerbatimEventQueue) lives in
 * its own file with zero AppKit dependency, making it independently
 * testable.
 */

#import "speech_bridge.h"

#import <AppKit/AppKit.h>

#import "log.h"
#import "verbatim_event_queue.h"

// ---------------------------------------------------------------------------
// SpeechBridge — global engine state
// ---------------------------------------------------------------------------
// These statics hold the current synthesizer, its delegate, and the
// session that's receiving events.  All access is guarded by
// g_engine_lock (NSLock).
//
// g_engine_lock     — NSLock guarding all global state below
// g_synth           — the current NSSpeechSynthesizer (nil if idle)
// g_delegate        — the delegate receiving callbacks (prevents ARC release)
// g_current_session — the session receiving word/finished events

static NSLock                         *g_engine_lock     = nil;
static NSSpeechSynthesizer            *g_synth           = nil;
static id<NSSpeechSynthesizerDelegate> g_delegate        = nil;
static VerbatimSession                *g_current_session = nil;

// ---------------------------------------------------------------------------
// Delegate — receives willSpeakWord / didFinishSpeaking callbacks
// ---------------------------------------------------------------------------

// VerbatimSpeechDelegate — the delegate object assigned to NSSpeechSynthesizer.
// Receives per-word timing callbacks and pushes NDJSON events into
// the VerbatimSession's queue.
@interface VerbatimSpeechDelegate : NSObject <NSSpeechSynthesizerDelegate>
@end

@implementation VerbatimSpeechDelegate

// ── willSpeakWord:ofString: ──────────────────────────────────────────────────
// Called by NSSpeechSynthesizer just before it speaks a word.
// Pushes a {"event":"word","start":N,"length":N} event into the
// session's queue.
//
// The characterRange is zero-indexed from the start of the text.
//
// Sender identity guard: if sender != g_synth, this callback is
// from a superseded synthesizer and is ignored.
- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender
            willSpeakWord:(NSRange)characterRange
                 ofString:(NSString *)string
{
	// Acquire the engine lock to read g_synth and g_current_session
	[g_engine_lock lock];

	// Ignore stray callbacks from a superseded synthesizer.
	// This happens when a new speak request interrupts the old one:
	// the old synth's delegate callbacks still fire for a brief window.
	if (sender != g_synth) {
		LOG_TRACE(@"speech: willSpeakWord IGNORED (stray callback from superseded synth)");
		[g_engine_lock unlock];
		return;
	}

	LOG_TRACE(@"speech: willSpeakWord start=%ld length=%ld",
	          (long) characterRange.location,
	          (long) characterRange.length);

	// Build the NDJSON event line
	NSString *json = [NSString stringWithFormat:@"{\"event\":\"word\",\"start\":%ld,\"length\":%ld}",
	                                            (long) characterRange.location,
	                                            (long) characterRange.length];

	// Capture the session while still holding the lock, then release
	// before pushing the event (to avoid holding the lock during I/O)
	VerbatimSession *session = g_current_session;
	[g_engine_lock unlock];

	// Push the event into the session's queue (thread-safe via NSCondition)
	[session pushEvent:json terminal:NO];
}

// ── didFinishSpeaking: ───────────────────────────────────────────────────────
// Called by NSSpeechSynthesizer when it finishes speaking.
// Pushes a {"event":"finished","completed":true/false} event and
// signals that the stream is over (terminal=YES).
//
// Also clears the global state (g_synth, g_delegate, g_current_session)
// so the next speak request can start fresh.
//
// Sender identity guard: same as willSpeakWord.
- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finishedSpeaking
{
	// Acquire the engine lock to read and modify global state
	[g_engine_lock lock];

	// Ignore stray callbacks from a superseded synthesizer
	if (sender != g_synth) {
		LOG_TRACE(@"speech: didFinishSpeaking IGNORED (stray callback from superseded synth)");
		[g_engine_lock unlock];
		return;
	}

	LOG_INFO(@"speech: finished, completed=%@", finishedSpeaking ? @"true" : @"false");

	// Build the final event line
	NSString *json = [NSString stringWithFormat:@"{\"event\":\"finished\",\"completed\":%@}",
	                                            finishedSpeaking ? @"true" : @"false"];

	// Capture the session, then clear global state
	VerbatimSession *session = g_current_session;

	g_synth           = nil;
	g_delegate        = nil;
	g_current_session = nil;
	[g_engine_lock unlock];

	// Push the terminal event (signals end of stream)
	[session pushEvent:json terminal:YES];
}

@end

// ---------------------------------------------------------------------------
// SpeechBridge — public API
// ---------------------------------------------------------------------------

@implementation SpeechBridge

// ── +initialize ──────────────────────────────────────────────────────────────
// Called once by the Objective-C runtime before the class is first used.
// Creates the engine lock (NSLock) that guards all global state.
//
// Using +initialize instead of dispatch_once or a lazy getter
// because it's the idiomatic ObjC pattern for one-time class setup.
+ (void)initialize
{
	if (self == [SpeechBridge class]) {
		g_engine_lock = [[NSLock alloc] init];
	}
}

// ── +resolveVoiceName: ───────────────────────────────────────────────────────
// Resolves a human-friendly voice name (e.g. "Albert") to an
// NSSpeechSynthesizer voice identifier.
//
// Performs a case-insensitive search through all available voices,
// comparing the NSVoiceName attribute (display name) against the
// requested name.
//
// Returns the voice identifier if found, or nil if not found
// (caller falls back to the default voice).
+ (NSString *)resolveVoiceName:(NSString *)name
{
	if (name.length == 0)
		return nil;

	// Lowercase for case-insensitive comparison
	NSString            *target = [name lowercaseString];
	NSArray<NSString *> *voices = [NSSpeechSynthesizer availableVoices];

	LOG_TRACE(@"speech: resolving voice '%@' (%lu voices available)",
	          name,
	          (unsigned long) voices.count);

	// Search through all available voices
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

// ── speakWithSession:text:rate:voiceName: ────────────────────────────────────
// Starts speaking `text`, interrupting whatever was previously speaking.
//
// This is the main entry point for TTS.  It:
//   1. Acquires the engine lock
//   2. Saves references to the previous session/synth
//   3. Resolves the voice name
//   4. Creates a new NSSpeechSynthesizer
//   5. Assigns the delegate and starts speaking
//   6. Releases the lock
//   7. Interrupts the previous synth (if any)
//
// The lock is released before calling startSpeakingString: because
// NSSpeechSynthesizer may need the main run loop to proceed, and
// we don't want to hold the lock during that.
+ (void)speakWithSession:(VerbatimSession *)session
                    text:(NSString *)text
                    rate:(float)rate
               voiceName:(NSString *)voiceName
{
	// ── Acquire lock ─────────────────────────────────────────────────────
	[g_engine_lock lock];
	LOG_TRACE(@"speech: speak — locked engine");

	// Save references to the previous session/synth so we can
	// interrupt them after releasing the lock
	VerbatimSession     *previous_session = g_current_session;
	NSSpeechSynthesizer *previous_synth   = g_synth;

	// ── Resolve voice name ───────────────────────────────────────────────
	// Map display name (e.g. "Albert") to voice identifier
	NSString *resolvedVoice = [self resolveVoiceName:voiceName];
	if (voiceName.length > 0 && resolvedVoice == nil) {
		LOG_WARN(@"speech: TTS-Voice '%@' not found on this system — using default voice",
		         voiceName);
	}

	LOG_INFO(@"speech: starting %lu chars, rate: %.0f wpm, voice: %@",
	         (unsigned long) text.length,
	         (double) rate,
	         voiceName.length > 0 ? voiceName : @"default");

	// ── Create synthesizer ───────────────────────────────────────────────
	NSSpeechSynthesizer *synth = [[NSSpeechSynthesizer alloc] initWithVoice:resolvedVoice];
	if (!synth) {
		// Failed to create synthesizer — notify all sessions and bail
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

	// ── Configure synthesizer ────────────────────────────────────────────
	VerbatimSpeechDelegate *delegate = [[VerbatimSpeechDelegate alloc] init];
	synth.delegate                   = delegate;  // Assign delegate before starting
	synth.rate                       = rate;      // Set speaking rate

	// ── Update global state ──────────────────────────────────────────────
	g_synth           = synth;
	g_delegate        = delegate;
	g_current_session = session;

	// ── Release lock ─────────────────────────────────────────────────────
	[g_engine_lock unlock];
	LOG_TRACE(@"speech: speak — unlocked engine");

	// ── Interrupt previous speech (after releasing lock) ──────────────────
	// The previous synth's delegate callbacks may still fire briefly
	// after interruption — that's why we have the sender identity guard.
	if (previous_session) {
		LOG_TRACE(@"speech: notifying previous session of interruption");
		[previous_session pushEvent:@"{\"event\":\"finished\",\"completed\":false}" terminal:YES];
	}
	if (previous_synth) {
		LOG_TRACE(@"speech: stopping previous synthesizer");
		[previous_synth stopSpeaking];
	}

	// ── Start speaking ───────────────────────────────────────────────────
	// Notify the session that speech has started
	[session pushEvent:@"{\"event\":\"started\"}" terminal:NO];

	// Actually start speaking.  This returns NO if the synthesizer
	// couldn't start (e.g. invalid voice, empty text).
	LOG_TRACE(@"speech: calling startSpeakingString");
	BOOL ok = [synth startSpeakingString:text];
	if (!ok) {
		LOG_ERROR(@"speech: startSpeakingString returned NO");
		[session pushEvent:@"{\"event\":\"error\",\"message\":\"startSpeaking returned false\"}"
		          terminal:YES];

		// Clean up global state if we're still the current synth
		// (another request may have started while we were starting)
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

// ── stop ─────────────────────────────────────────────────────────────────────
// Stops whatever is currently speaking, if anything.
//
// Acquires the engine lock, saves the current session/synth,
// clears global state, releases the lock, then sends the
// "finished" event and stops the synthesizer.
+ (void)stop
{
	[g_engine_lock lock];
	LOG_TRACE(@"speech: stop — locked engine");

	// Nothing to stop — return immediately
	if (!g_current_session) {
		LOG_DEBUG(@"speech: stop() called but nothing is speaking — nothing to do");
		[g_engine_lock unlock];
		return;
	}

	LOG_INFO(@"speech: stopping current utterance");

	// Save references and clear global state
	VerbatimSession     *session = g_current_session;
	NSSpeechSynthesizer *synth   = g_synth;

	g_synth           = nil;
	g_delegate        = nil;
	g_current_session = nil;
	[g_engine_lock unlock];
	LOG_TRACE(@"speech: stop — unlocked engine");

	// Send the "finished" event (not completed — we interrupted it)
	[session pushEvent:@"{\"event\":\"finished\",\"completed\":false}" terminal:YES];

	// Actually stop the synthesizer
	[synth stopSpeaking];
	LOG_TRACE(@"speech: stop — done");
}

// ── isSpeaking ───────────────────────────────────────────────────────────────
// Returns YES if the engine is currently speaking.
// Thread-safe (acquires the engine lock).
+ (BOOL)isSpeaking
{
	[g_engine_lock lock];
	BOOL speaking = g_current_session != nil;
	[g_engine_lock unlock];
	LOG_TRACE(@"speech: isSpeaking = %d", speaking);
	return speaking;
}

@end
