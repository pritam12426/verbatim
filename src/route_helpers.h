/*
 * route_helpers.h — shared utility class methods for route handlers.
 *
 * Provides common functionality used across all route handlers:
 *   - NSString (RouteHelpers) category for input validation
 *   - RouteHelpers class for speed mapping and JSON response helpers
 *
 * These are factored out of routes.m to avoid code duplication and
 * to keep each route handler focused on its specific logic.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── NSString (RouteHelpers) — input validation category ──────────────────────
// Adds convenience methods to NSString for common validation tasks
// used in route handlers.
@interface NSString (RouteHelpers)

// Returns YES if the string is empty or contains only whitespace.
// Used to validate that POST / request bodies are non-empty.
- (BOOL)isBlank;

@end

// ── RouteHelpers — shared route utility class ────────────────────────────────
// All class methods — no instances created.
@interface RouteHelpers : NSObject

// Maps TTS-Speed header value (1-10) to NSSpeechSynthesizer's
// words-per-minute rate.  Speed 1 maps to 90 WPM (slowest),
// speed 10 maps to 360 WPM (fastest).  Values outside 1-10
// are clamped to the nearest valid value.
+ (float)mapSpeedToRate:(int)speed;

// Serializes `object` and sends it as a complete JSON response.
// Uses JSONWriter for serialization and HttpResponse for sending.
// Falls back to a 500 error if serialization fails.
+ (void)sendJSONResponseWithFD:(int)fd
                    statusCode:(int)statusCode
                    statusText:(NSString *)statusText
                        object:(id)object;

// Sends a JSON error response with a message string.
// Convenience wrapper around sendJSONResponseWithFD: that wraps
// the message in {"error": "message"} format.
+ (void)sendJSONErrorWithFD:(int)fd
                 statusCode:(int)statusCode
                 statusText:(NSString *)statusText
                    message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
