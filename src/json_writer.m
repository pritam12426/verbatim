/*
 * json_writer.m — see json_writer.h for why this is just a thin wrapper
 * around NSJSONSerialization rather than a ported cJSON.
 */

#import "json_writer.h"

#import "log.h"

@implementation JSONWriter

+ (NSData *)serialize:(id)object
{
	LOG_TRACE(@"json: validating object");
	if (![NSJSONSerialization isValidJSONObject:object]) {
		LOG_ERROR(@"json: object is not valid top-level JSON (must be "
		          @"NSDictionary/NSArray of strings/numbers/booleans)");
		return nil;
	}

	LOG_TRACE(@"json: serializing object");
	NSError *error = nil;
	NSData  *data  = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];

	if (!data) {
		LOG_ERROR(@"json: serialization failed: %@", error.localizedDescription);
		return nil;
	}

	LOG_TRACE(@"json: serialized %lu bytes", (unsigned long) data.length);
	return data;
}

@end
