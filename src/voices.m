/*
 * voices.m — backs GET /voices.
 *
 * Matches lines like: "Albert              en_US    # Hello! ..."
 * POSIX ERE has no lazy quantifiers (unlike the Perl-style regex the
 * Swift version used), so a greedy `(.+)` is used instead — verified
 * against multi-word names ("Bad News") to confirm POSIX's
 * leftmost-longest matching still lands on the right boundary, at the
 * cost of pulling trailing whitespace into the captured name, which is
 * why rtrim() below is required (the Swift/PCRE version didn't need this
 * step).
 *
 * Ported from voices.c unchanged: popen() + <regex.h> are POSIX C, not
 * C++, and were never the reason this project needed an .mm file — that
 * was speech_bridge's std::queue alone. This logic is left exactly as it
 * was rather than switched to NSTask/NSRegularExpression, since it's
 * already the one piece of parsing in the project that's been carefully
 * verified against real `say -v '?'` output; a rewrite here would trade a
 * proven regex for an unproven one for no functional gain.
 */

#include "voices.h"

#include <ctype.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "log.h"

#define VOICES_CAPACITY_INITIAL 32

static VoiceInfo *g_cached = NULL;
static size_t g_cached_count = 0;

static void rtrim(char *s) {
	size_t n = strlen(s);
	while (n > 0 && isspace((unsigned char)s[n - 1])) {
		s[--n] = '\0';
	}
}

/* Reads all of `say -v '?'`'s stdout via popen. Returns a malloc'd,
 * NUL-terminated buffer the caller must free, or NULL on failure. */
static char *run_say_voice_list(void) {
	LOG_DEBUG(@"voices: launching `say -v '?'`");
	FILE *pipe = popen("/usr/bin/say -v '?' 2>/dev/null", "r");
	if (!pipe) {
		LOG_ERROR(@"voices: popen failed for `say -v '?'`");
		return NULL;
	}

	size_t cap = 8192, len = 0;
	char *buf = malloc(cap);
	if (!buf) {
		pclose(pipe);
		return NULL;
	}

	size_t n;
	while ((n = fread(buf + len, 1, cap - len - 1, pipe)) > 0) {
		len += n;
		if (len + 1 >= cap) {
			cap *= 2;
			char *grown = realloc(buf, cap);
			if (!grown) {
				free(buf);
				pclose(pipe);
				return NULL;
			}
			buf = grown;
		}
	}
	buf[len] = '\0';

	int status = pclose(pipe);
	LOG_DEBUG(@"voices: process exited status=%d, %zu bytes stdout", status, len);
	return buf;
}

static VoiceInfo *parse(const char *output, size_t *count) {
	regex_t re;
	if (regcomp(&re, "^(.+)[[:space:]]{2,}([A-Za-z_-]+)[[:space:]]+#", REG_EXTENDED) != 0) {
		LOG_ERROR(@"voices: failed to compile regex");
		*count = 0;
		return NULL;
	}

	size_t cap = VOICES_CAPACITY_INITIAL;
	VoiceInfo *results = malloc(cap * sizeof(VoiceInfo));
	size_t n = 0;

	/* Walk line by line without mutating `output` (strtok would). */
	const char *line_start = output;
	int lines_checked = 0, lines_matched = 0;

	while (*line_start) {
		const char *line_end = strchr(line_start, '\n');
		size_t line_len = line_end ? (size_t)(line_end - line_start) : strlen(line_start);

		if (line_len > 0 && line_len < 512) {
			char line[512];
			memcpy(line, line_start, line_len);
			line[line_len] = '\0';
			lines_checked++;

			regmatch_t m[3];
			if (regexec(&re, line, 3, m, 0) == 0) {
				if (n == cap) {
					cap *= 2;
					VoiceInfo *grown = realloc(results, cap * sizeof(VoiceInfo));
					if (!grown) break;
					results = grown;
				}

				int name_len = (int)(m[1].rm_eo - m[1].rm_so);
				int lang_len = (int)(m[2].rm_eo - m[2].rm_so);
				snprintf(results[n].name, sizeof(results[n].name), "%.*s", name_len,
				         line + m[1].rm_so);
				rtrim(results[n].name);
				snprintf(results[n].language, sizeof(results[n].language), "%.*s", lang_len,
				         line + m[2].rm_so);
				n++;
				lines_matched++;
			}
		}

		if (!line_end) break;
		line_start = line_end + 1;
	}

	regfree(&re);
	LOG_DEBUG(@"voices: parse complete — %d lines checked, %d matched, %zu results", lines_checked,
	          lines_matched, n);
	*count = n;
	return results;
}

VoiceInfo *voices_list(size_t *count) {
	if (g_cached) {
		LOG_DEBUG(@"voices: cache hit, returning %zu cached voices", g_cached_count);
		*count = g_cached_count;
		return g_cached;
	}

	LOG_DEBUG(@"voices: cache miss, shelling out");
	char *output = run_say_voice_list();
	if (!output) {
		LOG_WARN(@"voices: run_say_voice_list returned NULL");
		*count = 0;
		return NULL;
	}

	size_t n;
	VoiceInfo *voices = parse(output, &n);
	free(output);

	g_cached = voices;
	g_cached_count = n;
	LOG_DEBUG(@"voices: cached %zu voices", n);

	*count = n;
	return voices;
}
