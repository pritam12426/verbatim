/*
 * json_writer.m — see json_writer.h for why this is just a thin wrapper
 * around NSJSONSerialization rather than a ported cJSON.
 *
 * Implementation notes:
 *   - We call isValidJSONObject: before attempting serialization to
 *     get a clean error message if the object graph contains non-JSON
 *     types (e.g. NSDate, NSData, or custom objects).
 *   - We use options:0 (no pretty-printing) for compact output,
 *     which is important for the NDJSON streaming endpoint where
 *     every byte counts.
 *   - The returned NSData is UTF-8 encoded, ready to send over the wire.
 */

#import "json_writer.h"

#import "log.h"

@implementation JSONWriter

// ── serialize: ───────────────────────────────────────────────────────────────
// Serializes a JSON-compatible Foundation object graph into NSData.
//
// Step 1: Validate that the object is JSON-compatible (NSDictionary/NSArray
//         containing only strings, numbers, booleans, nulls, dicts, arrays).
// Step 2: Call NSJSONSerialization.dataWithJSONObject:options:error:.
// Step 3: Return the NSData on success, or nil on failure (with a log).
+ (NSData *)serialize:(id)object
{
	LOG_TRACE(@"json: validating object");

	// Step 1: Validate the object graph
	if (![NSJSONSerialization isValidJSONObject:object]) {
		LOG_ERROR(@"json: object is not valid top-level JSON (must be "
		          @"NSDictionary/NSArray of strings/numbers/booleans)");
		return nil;
	}

	// Step 2: Serialize
	LOG_TRACE(@"json: serializing object");
	NSError *error = nil;
	NSData  *data  = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];

	if (!data) {
		LOG_ERROR(@"json: serialization failed: %@", error.localizedDescription);
		return nil;
	}

	// Step 3: Return the result
	LOG_TRACE(@"json: serialized %lu bytes", (unsigned long) data.length);
	return data;
}

@end
