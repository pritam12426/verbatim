/*
 * http_server.m — minimal hand-rolled HTTP/1.1 server.
 *
 * Thread-per-connection via NSThread.
 *
 * This file contains the model @implementations (HttpHeader, HttpRequest,
 * ServerConfig), the per-connection handler, and the accept-loop entry
 * point.  Response-writing lives in HttpResponse, request parsing in
 * HttpParse.
 */

#import "http_server.h"

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

#import "http_parse.h"
#import "http_response.h"
#import "log.h"
#import "route_speak.h"
#import "routes.h"

static const NSUInteger kRecvChunk        = 4096;
static const NSUInteger kRecvMaxBodyBytes = 1024 * 1024; /* 1 MB */

// ---------------------------------------------------------------------------
// HttpHeader / HttpRequest / ServerConfig @implementation
// ---------------------------------------------------------------------------

@implementation HttpHeader
@end

@implementation HttpRequest
- (instancetype)init
{
	self = [super init];

	if (self) {
		_headers = [NSMutableArray array];
	}

	return self;
}
@end

@implementation ServerConfig
@end

// ---------------------------------------------------------------------------
// HttpServer
// ---------------------------------------------------------------------------

@implementation HttpServer

+ (void)handleConnectionWithFD:(int)fd config:(ServerConfig *)config
{
	LOG_TRACE(@"http: new connection on fd=%d", fd);

	NSString          *clientIP = @"?";
	struct sockaddr_in peer;
	socklen_t          peerLen = sizeof(peer);

	if (getpeername(fd, (struct sockaddr *) &peer, &peerLen) == 0) {
		char ipBuf[INET_ADDRSTRLEN] = "?";
		inet_ntop(AF_INET, &peer.sin_addr, ipBuf, sizeof(ipBuf));
		clientIP = [NSString stringWithUTF8String:ipBuf];
	}

	NSUInteger totalLen, headerEnd;
	NSData *raw = [HttpParse recvUntilHeadersDoneWithFD:fd totalLen:&totalLen headerEnd:&headerEnd];

	if (!raw) {
		LOG_TRACE(@"http: connection closed before headers complete (fd=%d)", fd);
		close(fd);
		return;
	}

	HttpRequest *req = [HttpParse parseHeadWithData:raw headerEnd:headerEnd];

	if (!req) {
		LOG_WARN(@"%@: malformed request line/headers", clientIP);
		close(fd);
		return;
	}

	/* Body: whatever's already past header_end in `raw` is the start of it;
	 * read the rest if Content-Length says there's more. */
	NSUInteger bodyHave         = totalLen - headerEnd;
	NSUInteger contentLength    = 0;
	NSString  *contentLengthHdr = [req headerWithName:@"Content-Length"];

	if (contentLengthHdr) {
		contentLength = (NSUInteger)[contentLengthHdr integerValue];
		LOG_TRACE(@"http: Content-Length = %lu", (unsigned long) contentLength);

		if (contentLength > kRecvMaxBodyBytes) {
			LOG_WARN(@"http: Content-Length %lu exceeds maximum %lu, rejecting",
			         (unsigned long) contentLength,
			         (unsigned long) kRecvMaxBodyBytes);
			close(fd);
			return;
		}
	}

	if (contentLength > 0) {
		LOG_TRACE(@"http: reading body (%lu bytes, have %lu)",
		          (unsigned long) contentLength,
		          (unsigned long) bodyHave);
		NSUInteger     toCopy   = bodyHave < contentLength ? bodyHave : contentLength;
		NSMutableData *bodyData = [[NSMutableData alloc] initWithCapacity:contentLength];
		[bodyData appendBytes:((const char *) raw.bytes + headerEnd) length:toCopy];
		NSUInteger remaining = contentLength - toCopy;
		while (remaining > 0) {
			char       chunk[kRecvChunk];
			NSUInteger chunkSize = remaining < kRecvChunk ? remaining : kRecvChunk;
			ssize_t    n         = recv(fd, chunk, chunkSize, 0);

			if (n <= 0) {
				LOG_TRACE(@"http: body recv returned %zd (remaining=%lu)",
				          n,
				          (unsigned long) remaining);
				break;
			}

			[bodyData appendBytes:chunk length:(NSUInteger) n];
			remaining -= (NSUInteger) n;
			LOG_TRACE(@"http: body recv %zd bytes (remaining=%lu)", n, (unsigned long) remaining);
		}
		req.body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
	}

	LOG_INFO(@"%@ %@ %@", clientIP, req.method, req.path);

	if ([req.method isEqualToString:@"POST"] && [req.path isEqualToString:@"/"]) {
		[Routes speakWithFD:fd request:req config:config clientIP:clientIP];
	} else if ([req.method isEqualToString:@"POST"] && [req.path isEqualToString:@"/stop"]) {
		[Routes stopWithFD:fd request:req clientIP:clientIP];
	} else if ([req.method isEqualToString:@"GET"] && [req.path isEqualToString:@"/status"]) {
		[Routes statusWithFD:fd request:req clientIP:clientIP];
	} else if ([req.method isEqualToString:@"GET"] && [req.path isEqualToString:@"/voices"]) {
		[Routes voicesWithFD:fd request:req clientIP:clientIP];
	} else {
		[Routes notFoundWithFD:fd];
	}

	LOG_TRACE(@"http: closing connection (fd=%d)", fd);
	close(fd);
}

// ---------------------------------------------------------------------------
// Server entry point — blocks forever
// ---------------------------------------------------------------------------

+ (int)runWithConfig:(ServerConfig *)config
{
	LOG_DEBUG(@"http: initializing server socket");

	int server_fd = socket(AF_INET, SOCK_STREAM, 0);

	if (server_fd < 0) {
		LOG_FATAL(@"http: socket() failed: %s", strerror(errno));
		return 1;
	}

	LOG_TRACE(@"http: server socket created (fd=%d)", server_fd);

	int yes = 1;
	setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
	LOG_TRACE(@"http: SO_REUSEADDR enabled");

	struct sockaddr_in addr = { 0 };
	addr.sin_family         = AF_INET;
	addr.sin_port           = htons(config.port);

	if (inet_pton(AF_INET, [config.host UTF8String], &addr.sin_addr) != 1) {
		LOG_FATAL(@"http: invalid host '%@'", config.host);
		close(server_fd);
		return 1;
	}

	if (bind(server_fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
		LOG_FATAL(@"http: bind(%@:%u) failed: %s", config.host, config.port, strerror(errno));
		close(server_fd);
		return 1;
	}
	LOG_DEBUG(@"http: bound to %@:%u", config.host, config.port);

	if (listen(server_fd, 16) < 0) {
		LOG_FATAL(@"http: listen() failed: %s", strerror(errno));
		close(server_fd);
		return 1;
	}
	LOG_DEBUG(@"http: listening (backlog=16)");

	LOG_INFO(@"verbatimd listening on http://%@:%u", config.host, config.port);

	while (YES) {
		int client_fd = accept(server_fd, NULL, NULL);

		if (client_fd < 0) {
			if (errno == EINTR)
				continue;
			LOG_WARN(@"http: accept() failed: %s", strerror(errno));
			continue;
		}

		LOG_TRACE(@"http: accepted connection (fd=%d)", client_fd);

		NSThread *thread = [[NSThread alloc] initWithBlock:^{
			[self handleConnectionWithFD:client_fd config:config];
		}];
		thread.name = [NSString stringWithFormat:@"com.pritam.verbatim.connection-%d", client_fd];
		[thread start];

		LOG_TRACE(@"http: spawned thread for fd=%d", client_fd);
	}
}

@end
