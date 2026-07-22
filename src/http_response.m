/*
 * http_response.m — HTTP response-writing functions.
 *
 * Self-contained "write half" of the HTTP layer: header lookup,
 * plain responses with Content-Length, and chunked streaming.
 * No parsing logic — purely output-side, depends only on POSIX send().
 */

#import "http_response.h"

#import <errno.h>
#import <sys/socket.h>

#import "log.h"

// ---------------------------------------------------------------------------
// HttpRequest (Headers) — case-insensitive header lookup
// ---------------------------------------------------------------------------

@implementation HttpRequest (Headers)

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

	if (send(fd, headerData.bytes, headerData.length, 0) < 0) {
		LOG_WARN(@"http: send(header) failed: %s", strerror(errno));
		return;
	}

	if (bodyLen > 0 && send(fd, body.bytes, body.length, 0) < 0) {
		LOG_WARN(@"http: send(body) failed: %s", strerror(errno));
	}
}

+ (void)beginChunkedWithFD:(int)fd contentType:(NSString *)contentType
{
	LOG_TRACE(@"http: starting chunked response (content-type: %@)", contentType);

	NSString *headerStr = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\n"
	                                                 @"Content-Type: %@\r\n"
	                                                 @"Transfer-Encoding: chunked\r\n"
	                                                 @"Connection: close\r\n"
	                                                 @"\r\n",
	                                                 contentType];

	NSData *headerData = [headerStr dataUsingEncoding:NSUTF8StringEncoding];

	if (send(fd, headerData.bytes, headerData.length, 0) < 0) {
		LOG_WARN(@"http: send(chunked header) failed: %s", strerror(errno));
	}
}

+ (void)writeChunkWithFD:(int)fd data:(NSData *)data
{
	if (data.length == 0)
		return;

	LOG_TRACE(@"http: writing chunk (%lu bytes)", (unsigned long) data.length);

	NSString *sizeLine = [NSString stringWithFormat:@"%lx\r\n", (unsigned long) data.length];
	NSData   *sizeData = [sizeLine dataUsingEncoding:NSUTF8StringEncoding];

	if (send(fd, sizeData.bytes, sizeData.length, 0) < 0)
		return;

	if (send(fd, data.bytes, data.length, 0) < 0)
		return;

	NSData *crlf = [@"\r\n" dataUsingEncoding:NSUTF8StringEncoding];
	if (send(fd, crlf.bytes, crlf.length, 0) < 0)
		return;
}

+ (void)endChunksWithFD:(int)fd
{
	LOG_TRACE(@"http: ending chunked response");
	NSData *terminator = [@"0\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
	send(fd, terminator.bytes, terminator.length, 0);
}

@end
