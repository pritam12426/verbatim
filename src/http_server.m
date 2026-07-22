/*
 * http_server.m — minimal hand-rolled HTTP/1.1 server.
 *
 * This is the core of the HTTP layer: socket setup, accept loop,
 * per-connection handling, and route dispatch.
 *
 * Thread model:
 *   - +runWithConfig: runs on a background thread (spawned by main.m).
 *     It creates a TCP socket, binds to the configured host:port,
 *     and loops forever in accept().
 *   - Each accepted connection gets its own NSThread, which calls
 *     +handleConnectionWithFD:config:.
 *   - The connection thread reads the request, dispatches to the
 *     appropriate route handler, and writes the response.
 *   - The main thread runs CFRunLoopRun() for speech delegate callbacks.
 *
 * This file contains:
 *   - @implementations for HttpHeader, HttpRequest, ServerConfig
 *   - +handleConnectionWithFD:config: — per-connection handler
 *   - +runWithConfig: — the accept loop entry point
 *
 * What lives elsewhere:
 *   - HttpResponse — response-writing class methods (http_response.m)
 *   - HttpParse    — request-parsing class methods (http_parse.m)
 *   - Routes       — route handlers (routes.m, route_speak.m)
 *
 * POSIX boundary:
 *   This file contains the most POSIX C in the ObjC codebase:
 *   socket(), bind(), listen(), accept(), recv(), send(), close(),
 *   getpeername(), inet_pton(), inet_ntop(), strerror(), setsockopt().
 *   These are at the POSIX boundary and cannot be wrapped in ObjC
 *   without losing their semantic clarity.  The rest of the HTTP layer
 *   (parsing, response writing) is pure ObjC.
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

// ── Constants ────────────────────────────────────────────────────────────────

// Size of each recv() chunk when reading the request body.
// 4096 is a common page size and works well for most request bodies.
static const NSUInteger kRecvChunk = 4096;

// Maximum request body size (1 MB).  Requests with Content-Length
// exceeding this are rejected immediately to prevent memory exhaustion.
static const NSUInteger kRecvMaxBodyBytes = 1024 * 1024;

// ---------------------------------------------------------------------------
// HttpHeader / HttpRequest / ServerConfig @implementation
// ---------------------------------------------------------------------------

// HttpHeader is a simple data container — no custom init needed.
@implementation HttpHeader
@end

// HttpRequest — custom init to pre-allocate the headers array.
// This avoids nil-checking on every header append in HttpParse.
@implementation HttpRequest
- (instancetype)init
{
	self = [super init];

	if (self) {
		// Pre-allocate with capacity for typical request (4-8 headers)
		_headers = [NSMutableArray array];
	}

	return self;
}
@end

// ServerConfig is a simple data container — no custom init needed.
@implementation ServerConfig
@end

// ---------------------------------------------------------------------------
// HttpServer
// ---------------------------------------------------------------------------

@implementation HttpServer

// ── Per-connection handler ───────────────────────────────────────────────────
// Called on a dedicated NSThread for each accepted connection.
// Reads the full HTTP request (headers + body), dispatches to the
// appropriate route handler, and closes the connection.
//
// Flow:
//   1. Extract client IP from the socket address (for logging)
//   2. Read headers via HttpParse.recvUntilHeadersDoneWithFD:
//   3. Parse request line + headers via HttpParse.parseHeadWithData:
//   4. Read body (if Content-Length > 0) via recv() loop
//   5. Dispatch to route handler based on method + path
//   6. Close the connection
+ (void)handleConnectionWithFD:(int)fd config:(ServerConfig *)config
{
	LOG_TRACE(@"http: new connection on fd=%d", fd);

	// Extract client IP for logging.  getpeername() gives us the
	// sockaddr_in of the connecting client, which we convert to a
	// dotted-decimal string via inet_ntop().
	NSString          *clientIP = @"?";
	struct sockaddr_in peer;
	socklen_t          peerLen = sizeof(peer);

	if (getpeername(fd, (struct sockaddr *) &peer, &peerLen) == 0) {
		char ipBuf[INET_ADDRSTRLEN] = "?";
		inet_ntop(AF_INET, &peer.sin_addr, ipBuf, sizeof(ipBuf));
		clientIP = [NSString stringWithUTF8String:ipBuf];
	}

	// Read from the socket until we find \r\n\r\n (end of headers).
	// Returns the raw data buffer and the offset past the blank line.
	NSUInteger totalLen, headerEnd;
	NSData *raw = [HttpParse recvUntilHeadersDoneWithFD:fd totalLen:&totalLen headerEnd:&headerEnd];

	if (!raw) {
		// Client closed the connection before sending complete headers
		LOG_TRACE(@"http: connection closed before headers complete (fd=%d)", fd);
		close(fd);
		return;
	}

	// Parse the request line ("GET / HTTP/1.1") and headers
	HttpRequest *req = [HttpParse parseHeadWithData:raw headerEnd:headerEnd];

	if (!req) {
		LOG_WARN(@"%@: malformed request line/headers", clientIP);
		close(fd);
		return;
	}

	// ── Read the request body (if any) ───────────────────────────────────
	// The body starts at offset headerEnd in `raw`.  We may already have
	// some bytes (bodyHave), and need to read the rest if Content-Length
	// says there's more.
	NSUInteger bodyHave         = totalLen - headerEnd;
	NSUInteger contentLength    = 0;
	NSString  *contentLengthHdr = [req headerWithName:@"Content-Length"];

	if (contentLengthHdr) {
		contentLength = (NSUInteger)[contentLengthHdr integerValue];
		LOG_TRACE(@"http: Content-Length = %lu", (unsigned long) contentLength);

		// Reject oversized bodies immediately (prevent memory exhaustion)
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

		// Copy whatever body bytes we already received from the header read
		NSUInteger     toCopy   = bodyHave < contentLength ? bodyHave : contentLength;
		NSMutableData *bodyData = [[NSMutableData alloc] initWithCapacity:contentLength];
		[bodyData appendBytes:((const char *) raw.bytes + headerEnd) length:toCopy];

		// Read the remaining body bytes in chunks
		NSUInteger remaining = contentLength - toCopy;
		while (remaining > 0) {
			char       chunk[kRecvChunk];
			NSUInteger chunkSize = remaining < kRecvChunk ? remaining : kRecvChunk;
			ssize_t    n         = recv(fd, chunk, chunkSize, 0);

			if (n <= 0) {
				// Connection closed or error before we got all the body
				LOG_TRACE(@"http: body recv returned %zd (remaining=%lu)",
				          n,
				          (unsigned long) remaining);
				break;
			}

			[bodyData appendBytes:chunk length:(NSUInteger) n];
			remaining -= (NSUInteger) n;
			LOG_TRACE(@"http: body recv %zd bytes (remaining=%lu)", n, (unsigned long) remaining);
		}

		// Convert body bytes to an NSString (UTF-8 encoding)
		req.body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
	}

	// ── Dispatch to route handler ────────────────────────────────────────
	// Match method + path against known routes.  This is a simple
	// if/else chain — no router library needed for 4 endpoints.
	LOG_INFO(@"%@ %@ %@", clientIP, req.method, req.path);

	if ([req.method isEqualToString:@"POST"] && [req.path isEqualToString:@"/"]) {
		// POST / — speak text (the most complex route, in route_speak.m)
		[Routes speakWithFD:fd request:req config:config clientIP:clientIP];
	} else if ([req.method isEqualToString:@"POST"] && [req.path isEqualToString:@"/stop"]) {
		// POST /stop — stop current speech
		[Routes stopWithFD:fd request:req clientIP:clientIP];
	} else if ([req.method isEqualToString:@"GET"] && [req.path isEqualToString:@"/status"]) {
		// GET /status — check if speaking
		[Routes statusWithFD:fd request:req clientIP:clientIP];
	} else if ([req.method isEqualToString:@"GET"] && [req.path isEqualToString:@"/voices"]) {
		// GET /voices — list available voices
		[Routes voicesWithFD:fd request:req clientIP:clientIP];
	} else {
		// Unknown route — 404
		[Routes notFoundWithFD:fd];
	}

	LOG_TRACE(@"http: closing connection (fd=%d)", fd);
	close(fd);
}

// ── Server entry point — blocks forever ──────────────────────────────────────
// Creates a TCP socket, binds to the configured host:port, and loops
// forever in accept().  Each accepted connection spawns a new NSThread
// that runs +handleConnectionWithFD:config:.
//
// This method never returns on success.  It only returns if a fatal
// error occurs (socket creation, bind, or listen failure).
//
// Called from main.m on a dedicated background thread.
+ (int)runWithConfig:(ServerConfig *)config
{
	LOG_DEBUG(@"http: initializing server socket");

	// Create a TCP socket (IPv4, stream)
	int server_fd = socket(AF_INET, SOCK_STREAM, 0);

	if (server_fd < 0) {
		LOG_FATAL(@"http: socket() failed: %s", strerror(errno));
		return 1;
	}

	LOG_TRACE(@"http: server socket created (fd=%d)", server_fd);

	// Allow immediate reuse of the port after restart (avoid TIME_WAIT)
	int yes = 1;
	setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
	LOG_TRACE(@"http: SO_REUSEADDR enabled");

	// Fill in the sockaddr_in structure
	struct sockaddr_in addr = { 0 };
	addr.sin_family         = AF_INET;
	addr.sin_port           = htons(config.port);

	// Convert the host string to a binary IP address
	if (inet_pton(AF_INET, [config.host UTF8String], &addr.sin_addr) != 1) {
		LOG_FATAL(@"http: invalid host '%@'", config.host);
		close(server_fd);
		return 1;
	}

	// Bind the socket to the address
	if (bind(server_fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
		LOG_FATAL(@"http: bind(%@:%u) failed: %s", config.host, config.port, strerror(errno));
		close(server_fd);
		return 1;
	}
	LOG_DEBUG(@"http: bound to %@:%u", config.host, config.port);

	// Start listening with a backlog of 16 (enough for a local tool)
	if (listen(server_fd, 16) < 0) {
		LOG_FATAL(@"http: listen() failed: %s", strerror(errno));
		close(server_fd);
		return 1;
	}
	LOG_DEBUG(@"http: listening (backlog=16)");

	// Log the listening address so the user knows where to connect
	LOG_INFO(@"verbatimd listening on http://%@:%u", config.host, config.port);

	// ── Accept loop ────────────────────────────────────────────────────
	// This loop runs forever (until the process is killed).
	// Each accepted connection gets its own NSThread.
	while (YES) {
		int client_fd = accept(server_fd, NULL, NULL);

		if (client_fd < 0) {
			if (errno == EINTR)
				continue;  // Interrupted by signal, retry
			LOG_WARN(@"http: accept() failed: %s", strerror(errno));
			continue;  // Non-fatal: log and keep accepting
		}

		LOG_TRACE(@"http: accepted connection (fd=%d)", client_fd);

		// Spawn a new thread for this connection.
		// NSThread is used instead of pthread because it integrates
		// with ARC and supports blocks for clean variable capture.
		NSThread *thread = [[NSThread alloc] initWithBlock:^{
			[self handleConnectionWithFD:client_fd config:config];
		}];
		thread.name = [NSString stringWithFormat:@"com.pritam.verbatim.connection-%d", client_fd];
		[thread start];

		LOG_TRACE(@"http: spawned thread for fd=%d", client_fd);
	}
}

@end
