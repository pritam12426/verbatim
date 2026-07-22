/*
 * json_writer.m — see json_writer.h for why this is just a thin wrapper
 * around NSJSONSerialization rather than a ported cJSON.
 */

#import "json_writer.h"

#import <string.h>

#import "log.h"

char *json_serialize_alloc(id object, size_t *out_len) {
	if (out_len) *out_len = 0;

	if (![NSJSONSerialization isValidJSONObject:object]) {
		LOG_ERROR(@"json: object is not valid top-level JSON (must be "
		          @"NSDictionary/NSArray of strings/numbers/booleans)");
		return NULL;
	}

	NSError *error = nil;
	NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
	if (!data) {
		LOG_ERROR(@"json: serialization failed: %@", error.localizedDescription);
		return NULL;
	}

	size_t len = data.length;
	char *buf = malloc(len + 1);
	if (!buf) {
		LOG_ERROR(@"json: malloc(%zu) failed", len + 1);
		return NULL;
	}

	memcpy(buf, data.bytes, len);
	buf[len] = '\0';

	if (out_len) *out_len = len;
	return buf;
}
