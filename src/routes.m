/*
 * routes.m — HTTP endpoint dispatch and simple handlers.
 *
 * The complex POST / handler (speak, NDJSON streaming) lives in
 * route_speak.m as a Routes category.  This file contains the
 * voices JSON cache, the stop/status/voices/404 handlers.
 *
 * Route dispatch:
 *   http_server.m matches method + path and calls the appropriate
 *   Routes class method.  There's no router library — with only 4
 *   endpoints, a hand-written if/else chain is clearer.
 *
 * Voices JSON cache:
 *   The first GET /voices request runs `say -v '?` via NSTask,
 *   parses the output into VoiceInfo objects, serializes to JSON,
 *   and caches the raw NSData bytes.  All subsequent requests send
 *   the cached bytes directly without re-running `say`.
 *   This is implemented via dispatch_once (thread-safe, runs once).
 */

#import "routes.h"

#import "http_response.h"
#import "json_writer.h"
#import "log.h"
#import "route_helpers.h"
#import "speech_bridge.h"
#import "voices.h"

// ── Voices JSON cache ────────────────────────────────────────────────────────
// First GET /voices serializes VoiceInfo objects to JSON bytes.
// All subsequent calls send the cached NSData directly.
// Lives for the process lifetime (never freed).
static NSData         *g_voices_json = nil;
static dispatch_once_t g_voices_once;

// ---------------------------------------------------------------------------
// Routes @implementation (simple handlers)
// ---------------------------------------------------------------------------

@implementation Routes

// ── POST /stop ───────────────────────────────────────────────────────────────
// Stops the current speech utterance (if any) and returns a JSON
// confirmation.  If nothing is speaking, this is a no-op (still
// returns 200 OK).
+ (void)stopWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP
{
	(void) req;  // Not used — stop doesn't need the request
	LOG_INFO(@"%@ POST /stop", clientIP);
	LOG_TRACE(@"routes: calling SpeechBridge.stop");
	[SpeechBridge stop];
	LOG_TRACE(@"routes: sending stopped response");
	[RouteHelpers sendJSONResponseWithFD:fd
	                          statusCode:200
	                          statusText:@"OK"
	                              object:@{ @"status": @"stopped" }];
}

// ── GET /status ──────────────────────────────────────────────────────────────
// Returns whether the engine is currently speaking.
// Response: {"speaking": true} or {"speaking": false}
+ (void)statusWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP
{
	(void) req;  // Not used — status doesn't need the request
	LOG_TRACE(@"routes: GET /status — checking speech state");
	BOOL speaking = [SpeechBridge isSpeaking];
	LOG_INFO(@"%@ GET /status — speaking: %@", clientIP, speaking ? @"true" : @"false");
	[RouteHelpers sendJSONResponseWithFD:fd
	                          statusCode:200
	                          statusText:@"OK"
	                              object:@{ @"speaking": @(speaking) }];
}

// ── GET /voices ──────────────────────────────────────────────────────────────
// Lists all available TTS voices on the system.
//
// First request: runs `say -v '?'` via NSTask, parses output into
// VoiceInfo objects, serializes to JSON, caches the raw bytes.
// Subsequent requests: sends the cached JSON bytes directly.
//
// Response: [{"name": "Albert", "language": "en_US"}, ...]
+ (void)voicesWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP
{
	(void) req;  // Not used — voices doesn't need the request

	// Build and cache the JSON on first request (thread-safe)
	dispatch_once(&g_voices_once, ^{
		LOG_DEBUG(@"voices: first request — building and caching JSON");

		// Run `say -v '?'` and parse the output
		NSArray<VoiceInfo *> *voices = [Voices voicesList];

		// Convert VoiceInfo objects to NSDictionary literals
		NSMutableArray<NSDictionary *> *arr = [NSMutableArray arrayWithCapacity:voices.count];
		for (VoiceInfo *v in voices) {
			[arr addObject:@{
				@"name": v.name,
				@"language": v.language,
			}];
		}

		// Serialize to JSON bytes
		g_voices_json = [JSONWriter serialize:arr];
		if (!g_voices_json) {
			LOG_ERROR(@"voices: JSON serialization failed");
		}
		LOG_DEBUG(@"voices: cached %lu bytes of JSON for %lu voices",
		          (unsigned long) g_voices_json.length,
		          (unsigned long) voices.count);
	});

	// Send the cached JSON (or an error if caching failed)
	if (!g_voices_json) {
		LOG_ERROR(@"voices: no cached JSON available");
		NSString *fallback = @"{\"error\":\"voice list unavailable\"}";
		NSData   *fbData   = [fallback dataUsingEncoding:NSUTF8StringEncoding];
		[HttpResponse sendWithFD:fd
		              statusCode:500
		              statusText:@"Internal Server Error"
		             contentType:@"application/json"
		                    body:fbData];
		return;
	}

	LOG_INFO(@"%@ GET /voices — sending %lu bytes (cached)",
	         clientIP,
	         (unsigned long) g_voices_json.length);
	[HttpResponse sendWithFD:fd
	              statusCode:200
	              statusText:@"OK"
	             contentType:@"application/json"
	                    body:g_voices_json];
}

// ── 404 Not Found ───────────────────────────────────────────────────────────
// Returns a JSON error response for unknown routes.
+ (void)notFoundWithFD:(int)fd
{
	LOG_TRACE(@"routes: sending 404 Not Found");
	NSString *body = @"{\"error\":\"not found\"}";
	NSData   *data = [body dataUsingEncoding:NSUTF8StringEncoding];
	[HttpResponse sendWithFD:fd
	              statusCode:404
	              statusText:@"Not Found"
	             contentType:@"application/json"
	                    body:data];
}

@end
