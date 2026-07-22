/*
 * json_writer.h — the only "JSON library" this project needs.
 *
 * Wraps NSJSONSerialization in a simple ObjC class interface.
 *
 * Why not cJSON (which the old C codebase used)?
 *   - NSJSONSerialization is already available on macOS via Foundation.
 *   - It handles all edge cases (unicode, escaping, nesting) correctly.
 *   - No external dependency to maintain or audit.
 *   - The wrapper is 30 lines of code — simpler than cJSON's API.
 *
 * Usage:
 *   NSDictionary *obj = @{@"status": @"ok", @"count": @(42)};
 *   NSData *json = [JSONWriter serialize:obj];
 *   // json now contains {"status":"ok","count":42}
 *
 * Constraints:
 *   - The top-level object must be an NSDictionary or NSArray.
 *   - All values must be NSString, NSNumber, NSNull, NSDictionary, or NSArray.
 *   - No NSData, NSDate, or other non-JSON types.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// JSONWriter — thin wrapper around NSJSONSerialization.
// All methods are class-level (no instances created).
@interface JSONWriter : NSObject

// Serializes a JSON-compatible Foundation object graph into NSData.
//
// Returns NSData containing the UTF-8 JSON representation of `object`,
// or nil if serialization fails (logs the error via LOG_ERROR).
//
// The returned NSData can be sent directly as a response body via
// HttpResponse.sendWithFD:statusText:contentType:body:.
+ (nullable NSData *)serialize:(id)object;

@end

NS_ASSUME_NONNULL_END
