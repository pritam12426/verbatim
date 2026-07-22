/*
 * route_helpers.m — shared utility functions for route handlers.
 *
 * Stateless helpers: input validation, speed mapping, word counting,
 * duration estimation, and JSON response serialization.
 */

#import "route_helpers.h"

#import <Foundation/Foundation.h>

#import "http_response.h"
#import "json_writer.h"
#import "log.h"

@implementation NSString (RouteHelpers)

- (BOOL)isBlank
{
	return self.length == 0 ||
	       [self stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
	               .length
	           == 0;
}

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
			inWord = NO;
		} else if (!inWord) {
			inWord = YES;
			count++;
		}
	}
	return count;
}

@end

@implementation RouteHelpers

+ (float)mapSpeedToRate:(int)speed
{
	int clamped = speed;
	if (clamped < 1)
		clamped = 1;
	if (clamped > 10)
		clamped = 10;
	return 90.0f + (float) (clamped - 1) * 30.0f;
}

+ (double)estimateDurationForWordCount:(NSUInteger)wordCount rateWPM:(float)rateWPM
{
	if (rateWPM <= 0.0f)
		return 0.0;
	return ((double) wordCount / (double) rateWPM) * 60.0;
}

+ (void)sendJSONResponseWithFD:(int)fd
                    statusCode:(int)statusCode
                    statusText:(NSString *)statusText
                        object:(id)object
{
	LOG_TRACE(@"routes: serializing JSON response (status=%d)", statusCode);

	NSData *data = [JSONWriter serialize:object];
	if (!data) {
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
