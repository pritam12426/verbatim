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

static int is_blank(const char *s) {
	while (*s) {
		if (!isspace((unsigned char)*s)) return 0;
		s++;
	}
	return 1;
}

/* TTS-Speed is a friendly 1 (slowest) - 10 (fastest) scale, mapped
 * linearly onto NSSpeechSynthesizer's words-per-minute rate — same
 * mapping as the Swift version's mapSpeedToRate(_:). */
static float map_speed_to_rate(int speed) {
	int clamped = speed;
	if (clamped < 1) clamped = 1;
	if (clamped > 10) clamped = 10;
	return 90.0f + (float)(clamped - 1) * 30.0f;
}

/* Whitespace-delimited word count. This is the one thing that has to
 * touch every byte of `text` — O(n) in text length — but that scan takes
 * microseconds even for long paragraphs, versus the seconds-to-minutes
 * the synthesizer itself will take to actually speak it. So while it
 * isn't literally O(1) in the strict sense, it's effectively instant
 * relative to real-time speech, which is what lets the estimate below go
 * out to the client before NSSpeechSynthesizer has spoken a single word. */
static size_t count_words(const char *text) {
	size_t count = 0;
	int in_word = 0;
	for (const char *p = text; *p; p++) {
		if (isspace((unsigned char)*p)) {
			in_word = 0;
		} else if (!in_word) {
			in_word = 1;
			count++;
		}
	}
	return count;
}

/* Heuristic duration estimate: word_count / rate(wpm) * 60. This is the
 * same estimate most TTS UIs use — NSSpeechSynthesizer has no public API
 * for predicted duration — and it's a heuristic, not a guarantee: real
 * speech isn't perfectly uniform per word (punctuation pauses, long
 * words, numbers spoken out, etc. all skew it). */
static double estimate_duration_seconds(size_t word_count, float rate_wpm) {
	if (rate_wpm <= 0.0f) return 0.0;
	return ((double)word_count / (double)rate_wpm) * 60.0;
}

/* Serializes `object` (an NSDictionary/NSArray literal) and sends it as
 * the full response body, then frees the intermediate buffer — the one
 * bit of bookkeeping every route needs since json_serialize_alloc()
 * hands back a malloc'd buffer rather than an ObjC object. */
static void send_json_response(int fd, int status_code, const char *status_text, id object) {
	size_t len;
	char *text = json_serialize_alloc(object, &len);
	if (!text) {
		static const char fallback[] = "{\"error\":\"internal JSON serialization failure\"}";
		http_send_response(fd, 500, "Internal Server Error", "application/json", fallback,
		                    strlen(fallback));
		return;
	}
	http_send_response(fd, status_code, status_text, "application/json", text, len);
	free(text);
}

static void send_json_error(int fd, int status_code, const char *status_text, const char *message) {
	send_json_response(fd, status_code, status_text, @{@"error" : @(message)});
}

void route_speak(int fd, const HttpRequest *req, const ServerConfig *config, const char *client_ip) {
	if (req->body == NULL || req->body_len == 0 || is_blank(req->body)) {
		LOG_WARN(@"%s POST / — 400 empty body", client_ip);
		send_json_error(fd, 400, "Bad Request", "request body must be non-empty text to speak");
		return;
	}

	const char *voice_header = http_get_header(req, "TTS-Voice");
	const char *speed_header = http_get_header(req, "TTS-Speed");
	const char *ndjson_header = http_get_header(req, "ndjson");

	float rate = config->default_rate;
	if (speed_header) {
		rate = map_speed_to_rate(atoi(speed_header));
	}

	int wants_ndjson = 1;
	if (ndjson_header && strcasecmp(ndjson_header, "false") == 0) {
		wants_ndjson = 0;
	}

	size_t word_count = count_words(req->body);
	double estimated_seconds = estimate_duration_seconds(word_count, rate);

	LOG_INFO(@"%s POST / — speaking %zu chars (~%zu words, ~%.1fs), voice: %s, rate: %.0f wpm, ndjson: %s",
	         client_ip, req->body_len, word_count, estimated_seconds,
	         voice_header ? voice_header : "default", (double)rate, wants_ndjson ? "true" : "false");

	if (wants_ndjson) {
		http_begin_chunked_response(fd, "application/x-ndjson");

		/* Written before verbatim_speak() is even called below, so the
		 * client learns the estimate before NSSpeechSynthesizer has
		 * spoken a single word — the whole point of computing it up
		 * front rather than waiting on real playback timing. */
		size_t est_len;
		char *est_text = json_serialize_alloc(@{
			@"event" : @"estimate",
			@"word_count" : @(word_count),
			@"estimated_seconds" : @(estimated_seconds),
		}, &est_len);
		if (est_text) {
			char with_newline[1200];
			int written = snprintf(with_newline, sizeof(with_newline), "%s\n", est_text);
			http_write_chunk(fd, with_newline, (size_t)written);
			free(est_text);
		}
	}

	VerbatimSession *session = verbatim_session_create();
	verbatim_speak(session, req->body, rate, voice_header);

	if (wants_ndjson) {
		char line[1024];
		size_t n;
		while ((n = verbatim_next_event(session, line, sizeof(line))) > 0) {
			char with_newline[1026];
			int written = snprintf(with_newline, sizeof(with_newline), "%s\n", line);
			http_write_chunk(fd, with_newline, (size_t)written);
		}
		http_end_chunks(fd);
	} else {
		/* ndjson: false — "run raw say": drain to completion, then a
		 * small status response, matching the Swift version's blocking
		 * withCheckedContinuation branch. The estimate is folded in here
		 * too so non-streaming callers still get it, just alongside the
		 * final result instead of up front. */
		char line[1024];
		while (verbatim_next_event(session, line, sizeof(line)) > 0) {
			/* discard — caller only wants completion, not the events */
		}
		send_json_response(fd, 200, "OK", @{
			@"status" : @"done",
			@"word_count" : @(word_count),
			@"estimated_seconds" : @(estimated_seconds),
		});
	}

	verbatim_session_destroy(session);
}

void route_stop(int fd, const HttpRequest *req, const char *client_ip) {
	(void)req;
	LOG_INFO(@"%s POST /stop", client_ip);
	verbatim_stop();
	send_json_response(fd, 200, "OK", @{@"status" : @"stopped"});
}

void route_status(int fd, const HttpRequest *req, const char *client_ip) {
	(void)req;
	int speaking = verbatim_is_speaking();
	LOG_INFO(@"%s GET /status — speaking: %s", client_ip, speaking ? "true" : "false");
	send_json_response(fd, 200, "OK", @{@"speaking" : @(speaking != 0)});
}

void route_voices(int fd, const HttpRequest *req, const char *client_ip) {
	(void)req;
	size_t count;
	VoiceInfo *voices = voices_list(&count);
	LOG_INFO(@"%s GET /voices — returning %zu voices", client_ip, count);

	NSMutableArray<NSDictionary *> *arr = [NSMutableArray arrayWithCapacity:count];
	for (size_t i = 0; i < count; i++) {
		[arr addObject:@{
			@"name" : @(voices[i].name),
			@"language" : @(voices[i].language),
		}];
	}

	send_json_response(fd, 200, "OK", arr);
	/* Note: `voices` itself is the module-level cache owned by voices.m —
	 * not freed here, same lifetime as the Swift version's `cached` array. */
}

void route_not_found(int fd) {
	const char *body = "{\"error\":\"not found\"}";
	http_send_response(fd, 404, "Not Found", "application/json", body, strlen(body));
}
