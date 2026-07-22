/*
 * routes.h — top-level route dispatch.
 *
 * Defines the Routes class, which handles all HTTP endpoints:
 *   POST /        — speak text (in route_speak.m as a category)
 *   POST /stop    — stop current speech
 *   GET  /status  — check if speaking
 *   GET  /voices  — list available TTS voices
 *
 * Route dispatch happens in http_server.m via a simple if/else chain
 * matching method + path.  There's no router library — with only 4
 * endpoints, a hand-written dispatch is clearer and faster.
 */

#import "http_server.h"

NS_ASSUME_NONNULL_BEGIN

// Routes — top-level route dispatch and simple handlers.
// The complex POST / handler lives in route_speak.m as a category.
@interface Routes : NSObject

// POST /stop — stop current speech.
// Returns {"status": "stopped"} on success.
+ (void)stopWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP;

// GET /status — check if the engine is currently speaking.
// Returns {"speaking": true/false}.
+ (void)statusWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP;

// GET /voices — list available TTS voices.
// Returns a JSON array of {name, language} objects.
// Results are cached after the first request (dispatch_once).
+ (void)voicesWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP;

// Returns a 404 JSON response for unknown routes.
+ (void)notFoundWithFD:(int)fd;

@end

NS_ASSUME_NONNULL_END
