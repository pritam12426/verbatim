/*
 * http_parse.m — HTTP request parsing.
 *
 * Self-contained "read half" of the HTTP layer: raw socket I/O to receive
 * headers, then parsing into HttpRequest objects.  No response logic —
 * purely input-side, depends only on POSIX recv() and Foundation.
 */

#import "http_parse.h"

#import <sys/socket.h>

#import "log.h"

static const NSUInteger kRecvInitialCap     = 8192;
static const NSUInteger kRecvMaxHeaderBytes = 64 * 1024;
static const NSInteger  kHTTPMaxHeaders     = 32;
static const NSInteger  kHTTPMaxHeaderName  = 64;
static const NSInteger  kHTTPMaxHeaderValue = 256;

@implementation HttpParse

+ (NSData *)recvUntilHeadersDoneWithFD:(int)fd
                              totalLen:(NSUInteger *)totalLen
                             headerEnd:(NSUInteger *)headerEnd
{
	NSMutableData *buf = [NSMutableData dataWithCapacity:kRecvInitialCap];
	NSUInteger     len = 0;

	while (YES) {
		// Ensure there's room for the next chunk plus a NUL sentinel
		if (len + 4096 > buf.length) {
			buf.length = len + 4096;
			LOG_TRACE(@"http: recv buffer grown to %lu bytes", (unsigned long) buf.length);
		}

		char   *mutableBytes = buf.mutableBytes;
		ssize_t n            = recv(fd, mutableBytes + len, buf.length - len, 0);

		if (n <= 0) {
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
			*totalLen  = len;
			*headerEnd = range.location + range.length;
			buf.length = len;
			LOG_TRACE(@"http: headers complete (%lu bytes, body at offset %lu)",
			          (unsigned long) len,
			          (unsigned long) *headerEnd);
			return [buf copy];
		}

		if (len > kRecvMaxHeaderBytes) {
			LOG_WARN(@"http: request headers exceeded %lu bytes, dropping connection",
			         (unsigned long) kRecvMaxHeaderBytes);
			return nil;
		}
	}
}

+ (HttpRequest *)parseHeadWithData:(NSData *)data headerEnd:(NSUInteger)headerEnd
{
	HttpRequest *req = [[HttpRequest alloc] init];

	NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	if (!raw)
		return nil;

	// Find first \r\n (end of request line)
	NSRange firstLine = [raw rangeOfString:@"\r\n"];
	if (firstLine.location == NSNotFound || firstLine.location >= headerEnd) {
		LOG_TRACE(@"http: parseHead failed — no request line found");
		return nil;
	}

	// Parse "METHOD PATH VERSION" from request line
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
	NSUInteger cursor      = firstLine.location + 2;
	NSUInteger headerCount = 0;

	while (cursor < headerEnd && headerCount < kHTTPMaxHeaders) {
		NSRange nextLine = [raw rangeOfString:@"\r\n"
		                              options:0
		                                range:NSMakeRange(cursor, headerEnd - cursor)];

		if (nextLine.location == NSNotFound || nextLine.location == cursor)
			break;

		NSRange colonRange = [raw rangeOfString:@":"
		                                options:0
		                                  range:NSMakeRange(cursor, nextLine.location - cursor)];

		if (colonRange.location != NSNotFound) {
			NSUInteger nameLen = colonRange.location - cursor;
			if (nameLen >= kHTTPMaxHeaderName)
				nameLen = kHTTPMaxHeaderName - 1;

			NSUInteger valueStart = colonRange.location + 1;
			// Skip leading whitespace
			while (valueStart < nextLine.location && [raw characterAtIndex:valueStart] == ' ') {
				valueStart++;
			}
			NSUInteger valueLen = nextLine.location - valueStart;
			if (valueLen >= kHTTPMaxHeaderValue)
				valueLen = kHTTPMaxHeaderValue - 1;

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
