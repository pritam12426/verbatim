/*
 * route_speak.h — POST / speak endpoint (Routes category).
 *
 * The most complex route: validates input, parses headers, computes
 * duration estimates, sets up NDJSON streaming, creates a speech
 * session, and streams/drains events.
 *
 * This is a category on Routes (defined in routes.h) to keep the
 * complex POST / handler separate from the simpler stop/status/
 * voices/404 handlers in routes.m.
 */

#import "routes.h"

NS_ASSUME_NONNULL_BEGIN

// Routes (Speak) — category implementing the POST / endpoint.
// Separated from routes.m because this handler is significantly
// more complex than the other three routes.
@interface Routes (Speak)

// Handles POST / — speak text via NSSpeechSynthesizer.
//
// Flow:
//   1. Validate request body (non-empty)
//   2. Parse TTS-Voice, TTS-Speed, ndjson headers
//   3. Map speed to rate, compute duration estimate
//   4. If ndjson=true: begin chunked response, send estimate event
//   5. Create VerbatimSession, start speech
//   6. Stream events (ndjson) or drain and send completion (non-ndjson)
//   7. Close connection
+ (void)speakWithFD:(int)fd
            request:(HttpRequest *)req
             config:(ServerConfig *)config
           clientIP:(NSString *)clientIP;

@end

NS_ASSUME_NONNULL_END
