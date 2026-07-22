/*
 * route_speak.m — POST / handler (Routes category).
 *
 * The most complex route: validates input, parses headers, sets up
 * NDJSON streaming, creates a speech session, and streams/drains events.
 *
 * This file is the heart of verbatimd.  It ties together the HTTP
 * layer (parsing, response writing), the speech layer (NSSpeechSynthesizer
 * via SpeechBridge), and the event queue (VerbatimSession) into a
 * single request handler.
 *
 * Request flow:
 *   1. Validate: body must be non-empty text
 *   2. Parse headers: TTS-Voice, TTS-Speed, ndjson
 *   3. Compute: map speed to rate
 *   4. If NDJSON:
 *      a. Begin chunked HTTP response
 *      b. Create VerbatimSession, start speech via SpeechBridge
 *      c. Stream events from session to HTTP response (blocking pull)
 *      d. End chunks when session signals completion
 *   5. If non-NDJSON:
 *      a. Create VerbatimSession, start speech
 *      b. Drain all events (discard them)
 *      c. Send a single JSON response with status
 *
 * The NDJSON streaming path is the default and the reason this project
 * exists: real-time, per-word timing events delivered as they happen,
 * before the synthesizer has finished speaking.
 */

#import "route_speak.h"

#import "http_response.h"
#import "log.h"
#import "route_helpers.h"
#import "speech_bridge.h"

@implementation Routes (Speak)

// ── speakWithFD:request:config:clientIP: ─────────────────────────────────────
// Handles POST / — speak text via NSSpeechSynthesizer.
//
// This is the most complex route in the project.  It validates the
// request, parses headers, optionally sets up NDJSON streaming,
// creates a speech session, and streams events back to the client.
//
// The NDJSON streaming path is the key feature: the client receives
// real-time per-word timing events as the synthesizer speaks, allowing
// it to highlight words and calculate progress.
+ (void)speakWithFD:(int)fd
            request:(HttpRequest *)req
             config:(ServerConfig *)config
           clientIP:(NSString *)clientIP
{
	LOG_TRACE(@"routes: POST / — validating request");

	// ── Step 1: Validate the request body ────────────────────────────────
	// The body must be non-empty, non-whitespace text to speak.
	if (req.body == nil || req.body.length == 0 || [req.body isBlank]) {
		LOG_WARN(@"%@ POST / — 400 empty body", clientIP);
		[RouteHelpers sendJSONErrorWithFD:fd
		                       statusCode:400
		                       statusText:@"Bad Request"
		                          message:@"request body must be non-empty text to speak"];
		return;
	}

	// ── Step 2: Parse custom headers ─────────────────────────────────────
	// TTS-Voice: name of the voice to use (e.g. "Albert", "Samantha")
	// TTS-Speed: friendly 1-10 scale (mapped to WPM below)
	// ndjson:    "false" to disable streaming (default: true)
	NSString *voiceHeader  = [req headerWithName:@"TTS-Voice"];
	NSString *speedHeader  = [req headerWithName:@"TTS-Speed"];
	NSString *ndjsonHeader = [req headerWithName:@"ndjson"];

	LOG_TRACE(@"routes: headers — voice=%@, speed=%@, ndjson=%@",
	          voiceHeader ? voiceHeader : @"(none)",
	          speedHeader ? speedHeader : @"(none)",
	          ndjsonHeader ? ndjsonHeader : @"(none)");

	// ── Step 3: Map speed to rate ────────────────────────────────────────
	// TTS-Speed is a friendly 1-10 scale, mapped linearly to WPM.
	// If no speed header, use the server's default rate.
	float rate = config.defaultRate;
	if (speedHeader) {
		NSScanner *scanner = [NSScanner scannerWithString:speedHeader];
		long long  speed   = 0;
		if (![scanner scanLongLong:&speed] || ![scanner isAtEnd]) {
			LOG_WARN(@"routes: invalid TTS-Speed header '%@', using default", speedHeader);
		} else {
			rate = [RouteHelpers mapSpeedToRate:(int) speed];
		}
		LOG_TRACE(@"routes: speed mapped to rate=%.0f wpm", (double) rate);
	}

	// ── Step 4: Check NDJSON preference ──────────────────────────────────
	// NDJSON streaming is on by default.  Client can disable with
	// "ndjson: false" header to get a single JSON response instead.
	BOOL wantsNDJSON = YES;
	if (ndjsonHeader && [ndjsonHeader caseInsensitiveCompare:@"false"] == NSOrderedSame) {
		wantsNDJSON = NO;
	}

	// Log the request at INFO level
	LOG_INFO(
	    @"%@ POST / — speaking %lu chars, voice: %@, rate: %.0f wpm, ndjson: %@",
	    clientIP,
	    (unsigned long) req.body.length,
	    voiceHeader ? voiceHeader : @"default",
	    (double) rate,
	    wantsNDJSON ? @"true" : @"false");

	// ── Step 6: NDJSON streaming path ────────────────────────────────────
	if (wantsNDJSON) {
		LOG_TRACE(@"routes: starting chunked NDJSON response");

		// Begin the chunked HTTP response
		[HttpResponse beginChunkedWithFD:fd contentType:@"application/x-ndjson"];

	}

	// ── Step 7: Create session and start speech ──────────────────────────
	// VerbatimSession is the bridge between the speech engine's delegate
	// callbacks and the HTTP response.  It owns a thread-safe queue that
	// the speech engine pushes events into and the HTTP thread pulls from.
	LOG_TRACE(@"routes: creating session and starting speech");
	VerbatimSession *session = [[VerbatimSession alloc] init];
	[SpeechBridge speakWithSession:session text:req.body rate:rate voiceName:voiceHeader];

	// ── Step 8: Stream or drain events ───────────────────────────────────
	if (wantsNDJSON) {
		// NDJSON streaming: pull events from the session and write them
		// as chunks to the HTTP response.  This blocks until the speech
		// engine signals completion (via the terminal event).
		LOG_TRACE(@"routes: streaming NDJSON events");
		NSString *line;
		while ((line = [session nextEvent]) != nil) {
			NSData *lineData = [[line stringByAppendingString:@"\n"]
			    dataUsingEncoding:NSUTF8StringEncoding];
			LOG_TRACE(@"routes: writing chunk (%lu bytes)", (unsigned long) lineData.length);
			[HttpResponse writeChunkWithFD:fd data:lineData];
		}
		LOG_TRACE(@"routes: NDJSON stream complete");
		[HttpResponse endChunksWithFD:fd];
	} else {
		// Non-NDJSON: drain all events (discard them) and send a single
		// JSON response with the final status and statistics.
		LOG_TRACE(@"routes: draining events (non-streaming mode)");
		while ([session nextEvent] != nil) {
			/* discard — caller only wants completion, not the events */
		}
		LOG_TRACE(@"routes: sending completion response");
		NSDictionary *resultDict = @{ @"status": @"done" };
		[RouteHelpers sendJSONResponseWithFD:fd statusCode:200 statusText:@"OK" object:resultDict];
	}
}

@end
