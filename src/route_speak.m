/*
 * route_speak.m — POST / handler (Routes category).
 *
 * The most complex route: validates input, parses headers, computes
 * duration estimates, sets up NDJSON streaming, creates a speech
 * session, and streams/drains events.
 */

#import "route_speak.h"

#import "http_response.h"
#import "json_writer.h"
#import "log.h"
#import "route_helpers.h"
#import "speech_bridge.h"

@implementation Routes (Speak)

+ (void)speakWithFD:(int)fd
            request:(HttpRequest *)req
             config:(ServerConfig *)config
           clientIP:(NSString *)clientIP
{
	LOG_TRACE(@"routes: POST / — validating request");

	if (req.body == nil || req.body.length == 0 || [req.body isBlank]) {
		LOG_WARN(@"%@ POST / — 400 empty body", clientIP);
		[RouteHelpers sendJSONErrorWithFD:fd
		                       statusCode:400
		                       statusText:@"Bad Request"
		                          message:@"request body must be non-empty text to speak"];
		return;
	}

	NSString *voiceHeader  = [req headerWithName:@"TTS-Voice"];
	NSString *speedHeader  = [req headerWithName:@"TTS-Speed"];
	NSString *ndjsonHeader = [req headerWithName:@"ndjson"];

	LOG_TRACE(@"routes: headers — voice=%@, speed=%@, ndjson=%@",
	          voiceHeader ? voiceHeader : @"(none)",
	          speedHeader ? speedHeader : @"(none)",
	          ndjsonHeader ? ndjsonHeader : @"(none)");

	float rate = config.defaultRate;
	if (speedHeader) {
		NSScanner *scanner = [NSScanner scannerWithString:speedHeader];
		long long  speed   = 0;
		if (![scanner scanLongLong:&speed] || ![scanner isAtEnd]) {
			LOG_WARN(@"routes: invalid TTS-Speed header '%@', using default", speedHeader);
		} else {
			rate = [RouteHelpers mapSpeedToRate:(int) speed];
		}
		LOG_TRACE(@"routes: speed mapped to rate=%.0f wpm", (double) rate);
	}

	BOOL wantsNDJSON = YES;
	if (ndjsonHeader && [ndjsonHeader caseInsensitiveCompare:@"false"] == NSOrderedSame) {
		wantsNDJSON = NO;
	}

	NSUInteger wordCount    = [req.body countWords];
	double estimatedSeconds = [RouteHelpers estimateDurationForWordCount:wordCount rateWPM:rate];

	LOG_INFO(
	    @"%@ POST / — speaking %lu chars (~%lu words, ~%.1fs), voice: %@, rate: %.0f wpm, ndjson: %@",
	    clientIP,
	    (unsigned long) req.body.length,
	    (unsigned long) wordCount,
	    estimatedSeconds,
	    voiceHeader ? voiceHeader : @"default",
	    (double) rate,
	    wantsNDJSON ? @"true" : @"false");

	if (wantsNDJSON) {
		LOG_TRACE(@"routes: starting chunked NDJSON response");
		[HttpResponse beginChunkedWithFD:fd contentType:@"application/x-ndjson"];

		NSDictionary *estimateDict = @{
			@"event": @"estimate",
			@"word_count": @(wordCount),
			@"estimated_seconds": @(estimatedSeconds),
		};
		NSData *estData = [JSONWriter serialize:estimateDict];
		if (estData) {
			NSMutableData *chunk = [estData mutableCopy];
			[chunk appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
			LOG_TRACE(@"routes: sending estimate event (%lu bytes)", (unsigned long) chunk.length);
			[HttpResponse writeChunkWithFD:fd data:chunk];
		}
	}

	LOG_TRACE(@"routes: creating session and starting speech");
	VerbatimSession *session = [[VerbatimSession alloc] init];
	[SpeechBridge speakWithSession:session text:req.body rate:rate voiceName:voiceHeader];

	if (wantsNDJSON) {
		LOG_TRACE(@"routes: streaming NDJSON events");
		NSString *line;
		while ((line = [session nextEvent]) != nil) {
			NSData *lineData = [[line stringByAppendingString:@"\n"]
			    dataUsingEncoding:NSUTF8StringEncoding];
			LOG_TRACE(@"routes: writing chunk (%lu bytes)", (unsigned long) lineData.length);
			[HttpResponse writeChunkWithFD:fd data:lineData];
		}
		LOG_TRACE(@"routes: NDJSON stream complete");
		[HttpResponse endChunksWithFD:fd];
	} else {
		LOG_TRACE(@"routes: draining events (non-streaming mode)");
		while ([session nextEvent] != nil) {
			/* discard */
		}
		LOG_TRACE(@"routes: sending completion response");
		NSDictionary *resultDict = @{
			@"status": @"done",
			@"word_count": @(wordCount),
			@"estimated_seconds": @(estimatedSeconds),
		};
		[RouteHelpers sendJSONResponseWithFD:fd statusCode:200 statusText:@"OK" object:resultDict];
	}
}

@end
