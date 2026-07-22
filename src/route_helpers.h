/*
 * route_helpers.h — shared utility class methods for route handlers
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSString (RouteHelpers)

// Returns YES if the string is empty or contains only whitespace.
- (BOOL)isBlank;

// Counts whitespace-delimited words in the string.
- (NSUInteger)countWords;

@end

@interface RouteHelpers : NSObject

// Maps TTS-Speed 1-10 to words-per-minute.
+ (float)mapSpeedToRate:(int)speed;

// Heuristic duration estimate: word_count / rate(wpm) * 60.
+ (double)estimateDurationForWordCount:(NSUInteger)wordCount rateWPM:(float)rateWPM;

// Serializes `object` and sends it as a complete JSON response.
+ (void)sendJSONResponseWithFD:(int)fd
                    statusCode:(int)statusCode
                    statusText:(NSString *)statusText
                        object:(id)object;

// Sends a JSON error response with a message string.
+ (void)sendJSONErrorWithFD:(int)fd
                 statusCode:(int)statusCode
                 statusText:(NSString *)statusText
                    message:(NSString *)message;

@end

NS_ASSUME_NONNULL_END
