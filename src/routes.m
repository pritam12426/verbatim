/*
 * routes.m — the four HTTP endpoints, direct behavioral port of the
 * Swift version's handleSpeak/route logic (verbatimd.swift) onto the C
 * speech_bridge.h pull-based interface.
 *
 * Ported from routes.c: the only real change is JSON construction. The
 * old file built cJSON objects field-by-field and printed them; this one
 * builds a plain NSDictionary/NSArray literal (the natural Objective-C
 * shape for the exact same data) and hands it to json_serialize_alloc(),
 * which wraps NSJSONSerialization — see json_writer.h for why that
 * replaces cJSON outright rather than porting it.
 *
 * route_speak also now sends a duration estimate (word_count / rate * 60)
 * before the synthesizer starts, rather than only reporting timing after
 * the fact — see count_words()/estimate_duration_seconds() below.
 *
 * This version wraps all handlers as class methods on Routes.
 */

#include "routes.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "json_writer.h"
#include "log.h"
#include "speech_bridge.h"
#include "voices.h"

static int is_blank(const char *s)
{
	while (*s) {
		if (!isspace((unsigned char) *s))
			return 0;
		s++;
	}
	return 1;
}

/* TTS-Speed is a friendly 1 (slowest) - 10 (fastest) scale, mapped
 * linearly onto NSSpeechSynthesizer's words-per-minute rate — same
 * mapping as the Swift version's mapSpeedToRate(_:). */
static float map_speed_to_rate(int speed)
{
	int clamped = speed;
	if (clamped < 1)
		clamped = 1;
	if (clamped > 10)
		clamped = 10;
	return 90.0f + (float) (clamped - 1) * 30.0f;
}

/* Whitespace-delimited word count. */
static size_t count_words(const char *text)
{
	size_t count   = 0;
	int    in_word = 0;
	for (const char *p = text; *p; p++) {
		if (isspace((unsigned char) *p)) {
			in_word = 0;
		} else if (!in_word) {
			in_word = 1;
			count++;
		}
	}
	return count;
}

/* Heuristic duration estimate: word_count / rate(wpm) * 60. */
static double estimate_duration_seconds(size_t word_count, float rate_wpm)
{
	if (rate_wpm <= 0.0f)
		return 0.0;
	return ((double) word_count / (double) rate_wpm) * 60.0;
}

/* Serializes `object` (an NSDictionary/NSArray literal) and sends it as
 * the full response body, then frees the intermediate buffer. */
static void send_json_response(int fd, int status_code, const char *status_text, id object)
{
	LOG_TRACE(@"routes: serializing JSON response (status=%d)", status_code);

	size_t len;
	char  *text = json_serialize_alloc(object, &len);
	if (!text) {
		LOG_ERROR(@"routes: JSON serialization failed");
		static const char fallback[] = "{\"error\":\"internal JSON serialization failure\"}";
		http_send_response(fd,
		                   500,
		                   "Internal Server Error",
		                   "application/json",
		                   fallback,
		                   strlen(fallback));
		return;
	}

	LOG_TRACE(@"routes: JSON response serialized (%zu bytes)", len);
	http_send_response(fd, status_code, status_text, "application/json", text, len);
	free(text);
}

static void send_json_error(int fd, int status_code, const char *status_text, const char *message)
{
	send_json_response(fd, status_code, status_text, @{@"error": @(message)});
}

// ---------------------------------------------------------------------------
// Routes @implementation
// ---------------------------------------------------------------------------

@implementation Routes

+ (void)speakWithFD:(int)fd
            request:(HttpRequest *)req
             config:(ServerConfig *)config
           clientIP:(NSString *)clientIP
{
	LOG_TRACE(@"routes: POST / — validating request");

	if (req.body == nil || req.body.length == 0 || is_blank([req.body UTF8String])) {
		LOG_WARN(@"%@ POST / — 400 empty body", clientIP);
		send_json_error(fd, 400, "Bad Request", "request body must be non-empty text to speak");
		return;
	}

	NSString *voiceHeader  = http_get_header(req, @"TTS-Voice");
	NSString *speedHeader  = http_get_header(req, @"TTS-Speed");
	NSString *ndjsonHeader = http_get_header(req, @"ndjson");

	LOG_TRACE(@"routes: headers — voice=%@, speed=%@, ndjson=%@",
	          voiceHeader ? voiceHeader : @"(none)",
	          speedHeader ? speedHeader : @"(none)",
	          ndjsonHeader ? ndjsonHeader : @"(none)");

	float rate = config.defaultRate;
	if (speedHeader) {
		rate = map_speed_to_rate(atoi([speedHeader UTF8String]));
		LOG_TRACE(@"routes: speed mapped to rate=%.0f wpm", (double) rate);
	}

	BOOL wantsNDJSON = YES;
	if (ndjsonHeader && [ndjsonHeader caseInsensitiveCompare:@"false"] == NSOrderedSame) {
		wantsNDJSON = NO;
	}

	const char *bodyCstr          = [req.body UTF8String];
	size_t      word_count        = count_words(bodyCstr);
	double      estimated_seconds = estimate_duration_seconds(word_count, rate);

	LOG_INFO(
	    @"%@ POST / — speaking %lu chars (~%zu words, ~%.1fs), voice: %@, rate: %.0f wpm, ndjson: %@",
	    clientIP,
	    (unsigned long) req.body.length,
	    word_count,
	    estimated_seconds,
	    voiceHeader ? voiceHeader : @"default",
	    (double) rate,
	    wantsNDJSON ? @"true" : @"false");

	if (wantsNDJSON) {
		LOG_TRACE(@"routes: starting chunked NDJSON response");
		http_begin_chunked_response(fd, "application/x-ndjson");

		/* Written before speech begins, so the client learns the estimate
		 * before NSSpeechSynthesizer has spoken a single word. */
		size_t est_len;
		char  *est_text = json_serialize_alloc(@{
            @"event": @"estimate",
            @"word_count": @(word_count),
            @"estimated_seconds": @(estimated_seconds),
        },
                                              &est_len);
		if (est_text) {
			char with_newline[1200];
			int  written = snprintf(with_newline, sizeof(with_newline), "%s\n", est_text);
			if (written > 0 && (size_t) written < sizeof(with_newline)) {
				LOG_TRACE(@"routes: sending estimate event (%d bytes)", written);
				http_write_chunk(fd, with_newline, (size_t) written);
			}
			free(est_text);
		}
	}

	LOG_TRACE(@"routes: creating session and starting speech");
	VerbatimSession *session = [[VerbatimSession alloc] init];
	[SpeechBridge speakWithSession:session text:req.body rate:rate voiceName:voiceHeader];

	if (wantsNDJSON) {
		LOG_TRACE(@"routes: streaming NDJSON events");
		NSString *line;
		while ((line = [session nextEvent]) != nil) {
			const char *lineCstr = [line UTF8String];
			char        with_newline[1026];
			int         written = snprintf(with_newline, sizeof(with_newline), "%s\n", lineCstr);
			if (written > 0 && (size_t) written < sizeof(with_newline)) {
				LOG_TRACE(@"routes: writing chunk (%d bytes)", written);
				http_write_chunk(fd, with_newline, (size_t) written);
			}
		}
		LOG_TRACE(@"routes: NDJSON stream complete");
		http_end_chunks(fd);
	} else {
		/* ndjson: false — drain to completion, then a small status response. */
		LOG_TRACE(@"routes: draining events (non-streaming mode)");
		while ([session nextEvent] != nil) {
			/* discard — caller only wants completion, not the events */
		}
		LOG_TRACE(@"routes: sending completion response");
		send_json_response(fd, 200, "OK", @{
			@"status": @"done",
			@"word_count": @(word_count),
			@"estimated_seconds": @(estimated_seconds),
		});
	}

	/* session is ARC-released when it goes out of scope */
	(void) session;
}

+ (void)stopWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP
{
	(void) req;
	LOG_INFO(@"%@ POST /stop", clientIP);
	LOG_TRACE(@"routes: calling SpeechBridge.stop");
	[SpeechBridge stop];
	LOG_TRACE(@"routes: sending stopped response");
	send_json_response(fd, 200, "OK", @{ @"status": @"stopped" });
}

+ (void)statusWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP
{
	(void) req;
	LOG_TRACE(@"routes: GET /status — checking speech state");
	BOOL speaking = [SpeechBridge isSpeaking];
	LOG_INFO(@"%@ GET /status — speaking: %@", clientIP, speaking ? @"true" : @"false");
	send_json_response(fd, 200, "OK", @{ @"speaking": @(speaking) });
}

+ (void)voicesWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP
{
	(void) req;
	LOG_TRACE(@"routes: GET /voices — fetching voice list");
	NSArray<VoiceInfo *> *voices = voicesList();
	LOG_INFO(@"%@ GET /voices — returning %lu voices", clientIP, (unsigned long) voices.count);

	NSMutableArray<NSDictionary *> *arr = [NSMutableArray arrayWithCapacity:voices.count];
	for (VoiceInfo *v in voices) {
		[arr addObject:@{
			@"name": v.name,
			@"language": v.language,
		}];
	}

	LOG_TRACE(@"routes: sending %lu voice entries", (unsigned long) arr.count);
	send_json_response(fd, 200, "OK", arr);
}

+ (void)notFoundWithFD:(int)fd
{
	LOG_TRACE(@"routes: sending 404 Not Found");
	const char *body = "{\"error\":\"not found\"}";
	http_send_response(fd, 404, "Not Found", "application/json", body, strlen(body));
}

@end
