/*
 * http_parse.m — HTTP request parsing.
 *
 * Self-contained "read half" of the HTTP layer: raw socket I/O to receive
 * headers, then parsing into HttpRequest objects.  No response logic —
 * purely input-side, depends only on POSIX recv() and Foundation.
 *
 * Parsing strategy:
 *   1. recv() in a loop, appending to an NSMutableData buffer.
 *   2. After each recv(), search the buffer for \r\n\r\n using
 *      NSData.rangeOfData: (Foundation's equivalent of memmem).
 *   3. Once found, convert the header portion to an NSString and
 *      parse the request line ("METHOD PATH VERSION") and headers.
 *   4. Return the raw data buffer + headerEnd offset to the caller,
 *      which uses these to read the request body.
 *
 * Why not use CFHTTPMessage?
 *   - It's a Core Foundation API that would add a framework dependency.
 *   - Our needs are simple: one request line + a handful of headers.
 *   - The hand-written parser is ~100 lines, well-tested, and has
 *     no magic (every byte position is explicit).
 *
 * Limits:
 *   - kRecvMaxHeaderBytes (64 KB) — maximum total header size
 *   - kHTTPMaxHeaders (32) — maximum number of header lines
 *   - kHTTPMaxHeaderName (64) — maximum header name length
 *   - kHTTPMaxHeaderValue (256) — maximum header value length
 *
 * These limits prevent abuse from malicious clients while being
 * generous enough for any legitimate HTTP request.
 */

#import "http_parse.h"

#import <sys/socket.h>

#import "log.h"

// ── Limits ───────────────────────────────────────────────────────────────────

// Initial capacity for the recv() buffer.  Most requests fit in
// under 2 KB, so starting at 8 KB avoids the first realloc.
static const NSUInteger kRecvInitialCap = 8192;

// Maximum total bytes we'll read before giving up (64 KB).
// If we haven't found \r\n\r\n by then, the request is malformed
// or the client is malicious.
static const NSUInteger kRecvMaxHeaderBytes = 64 * 1024;

// Maximum number of headers we'll parse (32).
// A typical request has 4-8 headers.  32 is generous but finite.
static const NSInteger kHTTPMaxHeaders = 32;

// Maximum header name length (64 bytes).
// RFC 7230 doesn't set a limit, but 64 covers all standard headers.
static const NSInteger kHTTPMaxHeaderName = 64;

// Maximum header value length (256 bytes).
// Most headers are under 100 bytes; 256 is generous.
static const NSInteger kHTTPMaxHeaderValue = 256;

@implementation HttpParse

// ── recvUntilHeadersDoneWithFD:totalLen:headerEnd: ───────────────────────────
// Reads from the socket until we find \r\n\r\n (the blank line that
// separates HTTP headers from the body).
//
// Uses NSData as a growable byte buffer.  After each recv(), we
// search the buffer for the 4-byte sequence \r\n\r\n using
// NSData.rangeOfData:options:range:, which is Foundation's
// equivalent of the POSIX memmem() function.
//
// Returns the raw buffer (including any body bytes received so far)
// and the offset past \r\n\r\n.
+ (NSData *)recvUntilHeadersDoneWithFD:(int)fd
                              totalLen:(NSUInteger *)totalLen
                             headerEnd:(NSUInteger *)headerEnd
{
	// Start with an 8 KB buffer (most requests fit in one chunk)
	NSMutableData *buf = [NSMutableData dataWithCapacity:kRecvInitialCap];
	NSUInteger     len = 0;  // Bytes received so far

	while (YES) {
		// Ensure there's room for the next recv chunk (4096 bytes)
		// plus a safety margin for the \r\n\r\n search.
		if (len + 4096 > buf.length) {
			buf.length = len + 4096;
			LOG_TRACE(@"http: recv buffer grown to %lu bytes", (unsigned long) buf.length);
		}

		// Recv into the mutable buffer at offset `len`
		char   *mutableBytes = buf.mutableBytes;
		ssize_t n            = recv(fd, mutableBytes + len, buf.length - len, 0);

		if (n <= 0) {
			// Connection closed (n == 0) or error (n < 0)
			LOG_TRACE(@"http: recv returned %zd (fd=%d)", n, fd);
			return nil;
		}

		len += (NSUInteger) n;

		LOG_TRACE(@"http: recv %zd bytes (total=%lu)", n, (unsigned long) len);

		// Search for \r\n\r\n in the received data
		NSRange range = [buf rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
		                         options:0
		                           range:NSMakeRange(0, len)];

		if (range.location != NSNotFound) {
			// Found the end of headers
			*totalLen  = len;                            // Total bytes received
			*headerEnd = range.location + range.length;  // Offset past \r\n\r\n
			buf.length = len;                            // Trim buffer to actual length
			LOG_TRACE(@"http: headers complete (%lu bytes, body at offset %lu)",
			          (unsigned long) len,
			          (unsigned long) *headerEnd);
			return [buf copy];  // Return an immutable copy
		}

		// Safety: bail if headers are too large (prevent memory exhaustion)
		if (len > kRecvMaxHeaderBytes) {
			LOG_WARN(@"http: request headers exceeded %lu bytes, dropping connection",
			         (unsigned long) kRecvMaxHeaderBytes);
			return nil;
		}
	}
}

// ── parseHeadWithData:headerEnd: ─────────────────────────────────────────────
// Parses the request line + headers from the first headerEnd bytes
// of data and returns a fully-populated HttpRequest object.
//
// Does NOT read the body — that's the caller's responsibility.
//
// Parsing steps:
//   1. Convert raw bytes to NSString (UTF-8)
//   2. Find the first \r\n (end of request line)
//   3. Split request line on spaces -> ["GET", "/", "HTTP/1.1"]
//   4. Walk header lines until we hit the blank line
//   5. Split each header on ":" -> name, value
//   6. Create HttpHeader objects and add to req.headers
+ (HttpRequest *)parseHeadWithData:(NSData *)data headerEnd:(NSUInteger)headerEnd
{
	HttpRequest *req = [[HttpRequest alloc] init];

	// Convert raw bytes to a string for parsing
	NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if (!raw)
		return nil;  // Data is not valid UTF-8

	// Find first \r\n (end of request line)
	NSRange firstLine = [raw rangeOfString:@"\r\n"];
	if (firstLine.location == NSNotFound || firstLine.location >= headerEnd) {
		LOG_TRACE(@"http: parseHead failed — no request line found");
		return nil;
	}

	// Parse "METHOD PATH VERSION" from request line
	// e.g. "GET / HTTP/1.1" -> ["GET", "/", "HTTP/1.1"]
	NSString *requestLine = [raw substringToIndex:firstLine.location];
	NSArray  *parts       = [requestLine componentsSeparatedByString:@" "];

	if (parts.count != 3) {
		LOG_TRACE(@"http: parseHead failed — request line has %lu parts != 3",
		          (unsigned long) parts.count);
		return nil;
	}

	req.method = parts[0];
	req.path   = parts[1];

	LOG_TRACE(@"http: parsed request line: %@ %@ %@", req.method, req.path, parts[2]);

	// Parse headers
	// Start scanning from after the first \r\n
	NSUInteger cursor      = firstLine.location + 2;
	NSUInteger headerCount = 0;

	// Walk line by line until we hit the blank line (headerEnd)
	while (cursor < headerEnd && headerCount < kHTTPMaxHeaders) {
		// Find the next \r\n
		NSRange nextLine = [raw rangeOfString:@"\r\n"
		                              options:0
		                                range:NSMakeRange(cursor, headerEnd - cursor)];

		if (nextLine.location == NSNotFound || nextLine.location == cursor)
			break;  // Empty line = end of headers

		// Find the colon separating header name from value
		NSRange colonRange = [raw rangeOfString:@":"
		                                options:0
		                                  range:NSMakeRange(cursor, nextLine.location - cursor)];

		if (colonRange.location != NSNotFound) {
			// Extract header name (before the colon)
			NSUInteger nameLen = colonRange.location - cursor;
			if (nameLen >= kHTTPMaxHeaderName)
				nameLen = kHTTPMaxHeaderName - 1;

			// Extract header value (after the colon, skip leading whitespace)
			NSUInteger valueStart = colonRange.location + 1;

			// Skip leading whitespace (RFC 7230: optional SP after colon)
			while (valueStart < nextLine.location && [raw characterAtIndex:valueStart] == ' ') {
				valueStart++;
			}

			NSUInteger valueLen = nextLine.location - valueStart;
			if (valueLen >= kHTTPMaxHeaderValue)
				valueLen = kHTTPMaxHeaderValue - 1;

			// Create the header object and add to the request
			HttpHeader *h = [[HttpHeader alloc] init];
			h.name        = [raw substringWithRange:NSMakeRange(cursor, nameLen)];
			h.value       = [raw substringWithRange:NSMakeRange(valueStart, valueLen)];
			[req.headers addObject:h];

			LOG_TRACE(@"http: parsed header '%@' = '%@'", h.name, h.value);
			headerCount++;
		}
		cursor = nextLine.location + 2;
	}

	LOG_TRACE(@"http: parsed %lu headers", (unsigned long) req.headers.count);
	return req;
}

@end
