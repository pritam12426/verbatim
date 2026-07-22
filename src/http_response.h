/*
 * http_response.h — HTTP response-writing class methods
 */

#import "http_server.h"

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// HttpRequest header lookup category
// ---------------------------------------------------------------------------

@interface HttpRequest (Headers)

// Case-insensitive header lookup, matching HTTP semantics.
- (NSString *_Nullable)headerWithName:(NSString *)name;

@end

// ---------------------------------------------------------------------------
// HttpResponse — response-writing class methods
// ---------------------------------------------------------------------------

@interface HttpResponse : NSObject

// Writes a complete, non-streamed HTTP response with Content-Length.
+ (void)sendWithFD:(int)fd
        statusCode:(int)statusCode
        statusText:(NSString *)statusText
       contentType:(NSString *)contentType
              body:(NSData *)body;

// Chunked streaming response (POST / with ndjson=true).
+ (void)beginChunkedWithFD:(int)fd contentType:(NSString *)contentType;
+ (void)writeChunkWithFD:(int)fd data:(NSData *)data;
+ (void)endChunksWithFD:(int)fd;

@end

NS_ASSUME_NONNULL_END
