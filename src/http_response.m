/*
 * http_response.m — HTTP response-writing functions.
 *
 * Self-contained "write half" of the HTTP layer: header lookup,
 * plain responses with Content-Length, and chunked streaming.
 * No parsing logic — purely output-side, depends only on POSIX send().
 *
 * Response formats:
 *
 *   Complete response (used by non-streaming routes):
 *     HTTP/1.1 200 OK\r\n
 *     Content-Type: application/json\r\n
 *     Content-Length: 42\r\n
 *     Connection: close\r\n
 *     \r\n
 *     {"status":"ok"}\n
 *
 *   Chunked response (used by POST / with ndjson=true):
 *     HTTP/1.1 200 OK\r\n
 *     Content-Type: application/x-ndjson\r\n
 *     Transfer-Encoding: chunked\r\n
 *     Connection: close\r\n
 *     \r\n
 *     1e\r\n{"event":"word","start":0,"length":5}\r\n
 *     ...
 *     0\r\n
 *     \r\n
 *
 * Error handling:
 *   send() failures are logged as warnings but not fatal — the
 *   connection is about to be closed anyway (Connection: close).
 */

#import "http_response.h"

#import <errno.h>
#import <sys/socket.h>

#import "log.h"

// ---------------------------------------------------------------------------
// HttpRequest (Headers) — case-insensitive header lookup
// ---------------------------------------------------------------------------

@implementation HttpRequest (Headers)

// Case-insensitive header lookup, matching HTTP semantics.
// Iterates through req.headers comparing each name case-insensitively.
// Returns the first matching header value, or nil if not found.
- (NSString *)headerWithName:(NSString *)name
{
	for (HttpHeader *h in self.headers) {
		if ([h.name caseInsensitiveCompare:name] == NSOrderedSame) {
			LOG_TRACE(@"http: header '%@' = '%@'", name, h.value);
			return h.value;
		}
	}
	LOG_TRACE(@"http: header '%@' not found", name);
	return nil;
}

@end

// ---------------------------------------------------------------------------
// HttpResponse — response-writing class methods
// ---------------------------------------------------------------------------

@implementation HttpResponse

// ── sendAll:data: ────────────────────────────────────────────────────────────
// Sends all bytes on fd, handling short writes (partial send).
// Returns YES if all bytes were sent, NO on error or disconnect.
+ (BOOL)sendAll:(int)fd data:(NSData *)data
{
	const char *bytes = (const char *) data.bytes;
	NSUInteger  total = data.length;
	NSUInteger  sent  = 0;

	while (sent < total) {
		ssize_t n = send(fd, bytes + sent, total - sent, 0);
		if (n <= 0) {
			if (n < 0 && errno == EINTR)
				continue;  // Interrupted by signal, retry
			return NO;     // Error or disconnect
		}
		sent += (NSUInteger) n;
	}
	return YES;
}

// ── sendWithFD:statusCode:statusText:contentType:body: ───────────────────────
// Writes a complete HTTP response with Content-Length.
//
// Builds the full HTTP response as an NSString (status line + headers
// + blank line), then sends the headers and body as two separate
// send() calls.  The Connection: close header tells the client not
// to reuse the TCP connection.
//
// Error handling: send() failures are logged but not fatal.
+ (void)sendWithFD:(int)fd
        statusCode:(int)statusCode
        statusText:(NSString *)statusText
       contentType:(NSString *)contentType
              body:(NSData *)body
{
	NSUInteger bodyLen = body.length;
	LOG_TRACE(@"http: sending response %d %@ (%lu bytes)",
	          statusCode,
	          statusText,
	          (unsigned long) bodyLen);

	// Build the HTTP response headers
	NSString *headerStr = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\n"
	                                                 @"Content-Type: %@\r\n"
	                                                 @"Content-Length: %lu\r\n"
	                                                 @"Connection: close\r\n"
	                                                 @"\r\n",
	                                                 statusCode,
	                                                 statusText,
	                                                 contentType,
	                                                 (unsigned long) bodyLen];

	NSData *headerData = [headerStr dataUsingEncoding:NSUTF8StringEncoding];

	// Send headers
	if (![self sendAll:fd data:headerData]) {
		LOG_WARN(@"http: send(header) failed");
		return;
	}

	// Send body (if any)
	if (bodyLen > 0 && ![self sendAll:fd data:body]) {
		LOG_WARN(@"http: send(body) failed");
	}
}

// ── beginChunkedWithFD:contentType: ──────────────────────────────────────────
// Sends the HTTP response headers for a chunked transfer.
// Returns YES on success, NO on failure (caller should abort the stream).
+ (BOOL)beginChunkedWithFD:(int)fd contentType:(NSString *)contentType
{
	LOG_TRACE(@"http: starting chunked response (content-type: %@)", contentType);

	// Build the response headers with Transfer-Encoding: chunked
	NSString *headerStr = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n"
	                                                 @"Content-Type: %@\r\n"
	                                                 @"Transfer-Encoding: chunked\r\n"
	                                                 @"Connection: close\r\n"
	                                                 @"\r\n",
	                                                 contentType];

	NSData *headerData = [headerStr dataUsingEncoding:NSUTF8StringEncoding];

	if (![self sendAll:fd data:headerData]) {
		LOG_WARN(@"http: send(chunked header) failed");
		return NO;
	}
	return YES;
}

// ── writeChunkWithFD:data: ───────────────────────────────────────────────────
// Sends a single chunk in HTTP chunked transfer encoding format:
//
//   <hex-size>\r\n
//   <data-bytes>\r\n
//
// For example, sending {"event":"word"}\n (15 bytes) would produce:
//   f\r\n{"event":"word"}\n\r\n
//
// The hex size is lowercase (per convention) and does not include
// leading zeros (e.g. "f" not "0f" or "000f").
+ (void)writeChunkWithFD:(int)fd data:(NSData *)data
{
	if (data.length == 0)
		return;

	LOG_TRACE(@"http: writing chunk (%lu bytes)", (unsigned long) data.length);

	// Format the hex size line: "1e\r\n"
	NSString *sizeLine = [NSString stringWithFormat:@"%lx\r\n", (unsigned long) data.length];
	NSData   *sizeData = [sizeLine dataUsingEncoding:NSUTF8StringEncoding];

	// Send size line
	if (![self sendAll:fd data:sizeData])
		return;

	// Send data
	if (![self sendAll:fd data:data])
		return;

	// Send trailing \r\n after data
	NSData *crlf = [@"\r\n" dataUsingEncoding:NSUTF8StringEncoding];
	[self sendAll:fd data:crlf];
}

// ── endChunksWithFD: ─────────────────────────────────────────────────────────
// Sends the terminating chunk that signals the end of the response.
//
// Format:
//   0\r\n     (zero-size chunk = end marker)
//   \r\n      (blank line after the last chunk)
+ (void)endChunksWithFD:(int)fd
{
	LOG_TRACE(@"http: ending chunked response");
	NSData *terminator = [@"0\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
	[self sendAll:fd data:terminator];
}

@end
