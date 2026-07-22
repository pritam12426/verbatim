/*
 * route_helpers.m — shared utility functions for route handlers.
 *
 * Stateless helpers: input validation, speed mapping, word counting,
 * duration estimation, and JSON response serialization.
 *
 * These are called from routes.m and route_speak.m.  They have no
 * state of their own — every function is pure (same inputs always
 * produce same outputs) except for the JSON response helpers, which
 * perform I/O.
 */

#import "route_helpers.h"

#import <Foundation/Foundation.h>

#import "http_response.h"
#import "json_writer.h"
#import "log.h"

// ── NSString (RouteHelpers) — input validation category ──────────────────────

@implementation NSString (RouteHelpers)

// Returns YES if the string is empty or contains only whitespace.
// Uses NSString's built-in whitespace character set, which includes
// spaces, tabs, newlines, and other Unicode whitespace characters.
//
// Used to validate that POST / request bodies are non-empty text.
- (BOOL)isBlank
{
	return self.length == 0 ||
	       [self stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
	               .length
	           == 0;
}

// Counts whitespace-delimited words in the string.
//
// Walks through each character, tracking whether we're "in a word"
// or "between words".  A word boundary is any whitespace character
// (space, tab, newline, carriage return).  This is a simple heuristic
// that works well for English text and most other languages.
//
// Used to estimate speech duration for the "estimate" event:
//   estimated_seconds = (word_count / rate_wpm) * 60
- (NSUInteger)countWords
{
	if (self.length == 0)
		return 0;

	NSUInteger count  = 0;
	BOOL       inWord = NO;
	NSUInteger length = self.length;

	for (NSUInteger i = 0; i < length; i++) {
		unichar c = [self characterAtIndex:i];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
			// Whitespace: we're between words
			inWord = NO;
		} else if (!inWord) {
			// Non-whitespace after whitespace: start of a new word
			inWord = YES;
			count++;
		}
	}
	return count;
}

@end

// ── RouteHelpers — shared route utility class ────────────────────────────────

@implementation RouteHelpers

// ── mapSpeedToRate: ──────────────────────────────────────────────────────────
// Maps TTS-Speed header value (1-10) to NSSpeechSynthesizer's
// words-per-minute rate.
//
// The mapping is linear:
//   speed 1  ->  90 WPM (slow, clear enunciation)
//   speed 5  -> 210 WPM (natural conversational pace)
//   speed 10 -> 360 WPM (very fast)
//
// Formula: rate = 90 + (clamped_speed - 1) * 30
//
// Values outside 1-10 are clamped to prevent extreme rates.
+ (float)mapSpeedToRate:(int)speed
{
	int clamped = speed;
	if (clamped < 1)
		clamped = 1;
	if (clamped > 10)
		clamped = 10;
	return 90.0f + (float) (clamped - 1) * 30.0f;
}

// ── estimateDurationForWordCount:rateWPM: ────────────────────────────────────
// Heuristic duration estimate: (word_count / rate_wpm) * 60.
//
// This is a rough approximation — actual speech rate varies by
// word complexity, punctuation, and the specific voice.  But it's
// good enough for the "estimate" event, which gives the client
// a ballpark figure before speech begins.
//
// Returns seconds as a double.
+ (double)estimateDurationForWordCount:(NSUInteger)wordCount rateWPM:(float)rateWPM
{
	if (rateWPM <= 0.0f)
		return 0.0;  // Guard against division by zero
	return ((double) wordCount / (double) rateWPM) * 60.0;
}

// ── sendJSONResponseWithFD:statusCode:statusText:object: ─────────────────────
// Serializes `object` and sends it as a complete JSON response.
//
// Flow:
//   1. Serialize via JSONWriter.serialize:
//   2. If serialization fails, send a 500 error with a fallback message
//   3. If successful, send the JSON body via HttpResponse.sendWithFD:
//
// Used by all route handlers that return JSON responses.
+ (void)sendJSONResponseWithFD:(int)fd
                    statusCode:(int)statusCode
                    statusText:(NSString *)statusText
                        object:(id)object
{
	LOG_TRACE(@"routes: serializing JSON response (status=%d)", statusCode);

	NSData *data = [JSONWriter serialize:object];
	if (!data) {
		// Serialization failed — send a 500 error
		LOG_ERROR(@"routes: JSON serialization failed");
		NSString *fallback = @"{\"error\":\"internal JSON serialization failure\"}";
		NSData   *fbData   = [fallback dataUsingEncoding:NSUTF8StringEncoding];
		[HttpResponse sendWithFD:fd
		              statusCode:500
		              statusText:@"Internal Server Error"
		             contentType:@"application/json"
		                    body:fbData];
		return;
	}

	LOG_TRACE(@"routes: JSON response serialized (%lu bytes)", (unsigned long) data.length);
	[HttpResponse sendWithFD:fd
	              statusCode:statusCode
	              statusText:statusText
	             contentType:@"application/json"
	                    body:data];
}

// ── sendJSONErrorWithFD:statusCode:statusText:message: ───────────────────────
// Sends a JSON error response with a message string.
//
// Wraps the message in {"error": "message"} format and delegates
// to sendJSONResponseWithFD:.
//
// Used by route handlers to report input validation errors (400),
// not-found errors (404), and other error conditions.
+ (void)sendJSONErrorWithFD:(int)fd
                 statusCode:(int)statusCode
                 statusText:(NSString *)statusText
                    message:(NSString *)message
{
	[self sendJSONResponseWithFD:fd
	                  statusCode:statusCode
	                  statusText:statusText
	                      object:@{ @"error": message }];
}

@end
