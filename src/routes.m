/*
 * routes.m — HTTP endpoint dispatch and simple handlers.
 *
 * The complex POST / handler (speak, NDJSON streaming) lives in
 * route_speak.m as a Routes category.  This file contains the voices
 * JSON cache, the stop/status/voices/404 handlers.
 */

#import "routes.h"

#import "http_response.h"
#import "json_writer.h"
#import "log.h"
#import "route_helpers.h"
#import "speech_bridge.h"
#import "voices.h"

// ---------------------------------------------------------------------------
// Voices JSON cache — first GET /voices serializes, all subsequent calls
// send the cached bytes directly.  Lives for the process lifetime.
// ---------------------------------------------------------------------------

static NSData         *g_voices_json = nil;
static dispatch_once_t g_voices_once;

// ---------------------------------------------------------------------------
// Routes @implementation (simple handlers)
// ---------------------------------------------------------------------------

@implementation Routes

+ (void)stopWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP
{
	(void) req;
	LOG_INFO(@"%@ POST /stop", clientIP);
	LOG_TRACE(@"routes: calling SpeechBridge.stop");
	[SpeechBridge stop];
	LOG_TRACE(@"routes: sending stopped response");
	[RouteHelpers sendJSONResponseWithFD:fd
	                          statusCode:200
	                          statusText:@"OK"
	                              object:@{ @"status": @"stopped" }];
}

+ (void)statusWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP
{
	(void) req;
	LOG_TRACE(@"routes: GET /status — checking speech state");
	BOOL speaking = [SpeechBridge isSpeaking];
	LOG_INFO(@"%@ GET /status — speaking: %@", clientIP, speaking ? @"true" : @"false");
	[RouteHelpers sendJSONResponseWithFD:fd
	                          statusCode:200
	                          statusText:@"OK"
	                              object:@{ @"speaking": @(speaking) }];
}

+ (void)voicesWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP
{
	(void) req;

	dispatch_once(&g_voices_once, ^{
		LOG_DEBUG(@"voices: first request — building and caching JSON");
		NSArray<VoiceInfo *> *voices = [Voices voicesList];

		NSMutableArray<NSDictionary *> *arr = [NSMutableArray arrayWithCapacity:voices.count];
		for (VoiceInfo *v in voices) {
			[arr addObject:@{
				@"name": v.name,
				@"language": v.language,
			}];
		}

		g_voices_json = [JSONWriter serialize:arr];
		if (!g_voices_json) {
			LOG_ERROR(@"voices: JSON serialization failed");
		}
		LOG_DEBUG(@"voices: cached %lu bytes of JSON for %lu voices",
		          (unsigned long) g_voices_json.length,
		          (unsigned long) voices.count);
	});

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
