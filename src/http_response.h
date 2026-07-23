/*
 * http_response.h — HTTP response-writing class methods.
 *
 * Self-contained "write half" of the HTTP layer.  Provides:
 *   - Header lookup: HttpRequest (Headers) category for case-insensitive
 *     header access by name.
 *   - Complete responses: HttpResponse.sendWithFD: for non-streamed
 *     responses with Content-Length.
 *   - Chunked streaming: begin/write/end methods for Transfer-Encoding
 *     chunked, used by the NDJSON streaming endpoint (POST /).
 *
 * No parsing logic — purely output-side.  Depends only on POSIX send().
 *
 * Usage (called from route handlers):
 *   [HttpResponse sendWithFD:fd statusCode:200 statusText:@"OK"
 *                contentType:@"application/json" body:jsonData];
 */

#import "http_server.h"

NS_ASSUME_NONNULL_BEGIN

// ── HttpRequest header lookup category ───────────────────────────────────────
// Adds a -headerWithName: method to HttpRequest for convenient
// case-insensitive header access.  HTTP header names are
// case-insensitive per RFC 7230, so "Content-Type" and
// "content-type" should match the same header.
@interface HttpRequest (Headers)

// Case-insensitive header lookup, matching HTTP semantics.
// Returns the header value, or nil if no header with that name exists.
- (NSString *_Nullable)headerWithName:(NSString *)name;

@end

// ── HttpResponse — response-writing class methods ────────────────────────────
// All methods are class-level (no instances created).
// Each method takes a file descriptor (fd) and writes directly to it
// via POSIX send().
@interface HttpResponse : NSObject

// Sends all bytes on fd, handling short writes.  Returns YES on success,
// NO on error/disconnect.  Wraps POSIX send() in a loop.
+ (BOOL)sendAll:(int)fd data:(NSData *)data;

// Writes a complete, non-streamed HTTP response with Content-Length.
//
// Sends the full HTTP response (status line + headers + body) in one
// shot.  The Connection: close header is always sent, so the client
// knows not to reuse the connection.
//
// Used by simple routes (GET /status, GET /voices, POST /stop, 404).
+ (void)sendWithFD:(int)fd
        statusCode:(int)statusCode
        statusText:(NSString *)statusText
       contentType:(NSString *)contentType
              body:(NSData *)body;

// ── Chunked streaming response ──────────────────────────────────────────────
// Used by POST / with ndjson=true.  The response is sent in chunks,
// each prefixed with its hex size per RFC 7230 §4.1.
//
// Flow:
//   1. beginChunkedWithFD: — sends the HTTP response headers
//   2. writeChunkWithFD:data: — sends one or more data chunks
//   3. endChunksWithFD: — sends the terminating "0\r\n\r\n"

// Sends the HTTP response headers for a chunked transfer.
// Returns YES on success, NO on failure.
+ (BOOL)beginChunkedWithFD:(int)fd contentType:(NSString *)contentType;

// Sends a single chunk: hex-size\r\n data \r\n
+ (void)writeChunkWithFD:(int)fd data:(NSData *)data;

// Sends the terminating chunk: "0\r\n\r\n"
+ (void)endChunksWithFD:(int)fd;

@end

NS_ASSUME_NONNULL_END
