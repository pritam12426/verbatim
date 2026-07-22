/*
 * http_server.m — minimal hand-rolled HTTP/1.1 server.
 *
 * Deliberately small: only what verbatimd's four routes need (GET/POST,
 * headers, Content-Length request bodies, chunked-encoded streaming
 * responses). Thread-per-connection via pthread, matching log.m's/
 * routes.m's use of plain POSIX/Foundation APIs — no async runtime, no
 * reactor, matching the "no hidden thread pool" goal that motivated
 * moving off Swift Concurrency in the first place.
 *
 * Ported from the old verbatim_ojb_cpp_C project's http_server.c: this
 * file was already plain C with no C++ in it, so going "100% Objective-C"
 * for this file just means it now compiles as one (Objective-C is a
 * strict superset of C — sockets, pthreads, and printf-family calls need
 * no changes to build in a .m file). Logic below is otherwise unchanged
 * from the proven, curl-tested original.
 *
 * This version replaces C structs with ObjC objects (HttpRequest,
 * HttpHeader, ServerConfig) as declared in http_server.h.
 */

#include "http_server.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h> /* strcasecmp */
#include <sys/socket.h>
#include <unistd.h>

#include "log.h"
#include "routes.h"

#define RECV_INITIAL_CAP      8192
#define RECV_MAX_HEADER_BYTES (64 * 1024)
#define RECV_CHUNK            4096

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
// C functions declared in http_server.h
// ---------------------------------------------------------------------------

NSString *http_get_header(HttpRequest *req, NSString *name)
{
	for (HttpHeader *h in req.headers) {
		if ([h.name caseInsensitiveCompare:name] == NSOrderedSame) {
			return h.value;
		}
	}
	return nil;
}

void http_send_response(int         fd,
                        int         status_code,
                        const char *status_text,
                        const char *content_type,
                        const char *body,
                        size_t      body_len)
{
	char header[512];
	int  n = snprintf(header,
                     sizeof(header),
                     "HTTP/1.1 %d %s\r\n"
	                  "Content-Type: %s\r\n"
	                  "Content-Length: %zu\r\n"
	                  "Connection: close\r\n"
	                  "\r\n",
                     status_code,
                     status_text,
                     content_type,
                     body_len);

	if (n < 0 || (size_t) n >= sizeof(header)) {
		LOG_ERROR(@"http: response header truncated");
		return;
	}

	if (send(fd, header, (size_t) n, 0) < 0) {
		LOG_WARN(@"http: send(header) failed: %s", strerror(errno));
		return;
	}

	if (body_len > 0 && send(fd, body, body_len, 0) < 0) {
		LOG_WARN(@"http: send(body) failed: %s", strerror(errno));
	}
}

void http_begin_chunked_response(int fd, const char *content_type)
{
	char header[256];
	int  n = snprintf(header,
                     sizeof(header),
                     "HTTP/1.1 200 OK\r\n"
	                  "Content-Type: %s\r\n"
	                  "Transfer-Encoding: chunked\r\n"
	                  "Connection: close\r\n"
	                  "\r\n",
                     content_type);

	if (n < 0 || (size_t) n >= sizeof(header)) {
		LOG_ERROR(@"http: chunked response header truncated");
		return;
	}

	if (send(fd, header, (size_t) n, 0) < 0) {
		LOG_WARN(@"http: send(chunked header) failed: %s", strerror(errno));
	}
}

void http_write_chunk(int fd, const char *data, size_t len)
{
	if (len == 0)
		return; /* a zero-length chunk would be misread as the terminator */

	char size_line[32];
	int  n = snprintf(size_line, sizeof(size_line), "%zx\r\n", len);

	if (send(fd, size_line, (size_t) n, 0) < 0)
		return;

	if (send(fd, data, len, 0) < 0)
		return;

	if (send(fd, "\r\n", 2, 0) < 0)
		return;
}

void http_end_chunks(int fd)
{
	send(fd, "0\r\n\r\n", 5, 0);
}

// ---------------------------------------------------------------------------
// Request parsing — raw C socket I/O, result is ObjC objects
// ---------------------------------------------------------------------------

static char *recv_until_headers_done(int fd, size_t *total_len, size_t *header_end)
{
	size_t cap = RECV_INITIAL_CAP;
	char  *buf = malloc(cap);

	if (!buf)
		return NULL;

	size_t len = 0;

	for (;;) {
		if (len + 1 >= cap) {
			cap         *= 2;
			char *grown  = realloc(buf, cap);
			if (!grown) {
				free(buf);
				return NULL;
			}
			buf = grown;
		}

		ssize_t n = recv(fd, buf + len, cap - len - 1, 0);

		if (n <= 0) {
			free(buf);
			return NULL;
		}

		len      += (size_t) n;
		buf[len]  = '\0';

		char *found = strstr(buf, "\r\n\r\n");

		if (found) {
			*total_len  = len;
			*header_end = (size_t) (found + 4 - buf);
			return buf;
		}

		if (len > RECV_MAX_HEADER_BYTES) {
			LOG_WARN(@"http: request headers exceeded %d bytes, dropping connection",
			         RECV_MAX_HEADER_BYTES);
			free(buf);
			return NULL;
		}
	}
}

// Parses the request line + headers from buf[0..header_end) and returns
// a fully-populated HttpRequest object.  Does NOT read the body — caller
// does that separately once Content-Length is known.
static HttpRequest *parse_head(const char *buf, size_t header_end)
{
	HttpRequest *req = [[HttpRequest alloc] init];

	const char *line_end = strstr(buf, "\r\n");

	if (!line_end || line_end - buf >= (long) header_end)
		return nil;

	char method[8], path[512], version[16];
	int  matched = sscanf(buf, "%7s %511s %15s", method, path, version);

	if (matched != 3)
		return nil;

	req.method = [NSString stringWithUTF8String:method];
	req.path   = [NSString stringWithUTF8String:path];

	const char *cursor = line_end + 2;
	while (cursor < buf + header_end && (int) req.headers.count < HTTP_MAX_HEADERS) {
		const char *next_line = strstr(cursor, "\r\n");

		if (!next_line || next_line == cursor)
			break; /* blank line = end of headers */

		const char *colon = memchr(cursor, ':', (size_t) (next_line - cursor));

		if (colon) {
			size_t name_len = (size_t) (colon - cursor);

			if (name_len >= HTTP_MAX_HEADER_NAME)
				name_len = HTTP_MAX_HEADER_NAME - 1;

			const char *value_start = colon + 1;
			while (value_start < next_line && *value_start == ' ')
				value_start++;
			size_t value_len = (size_t) (next_line - value_start);

			if (value_len >= HTTP_MAX_HEADER_VALUE)
				value_len = HTTP_MAX_HEADER_VALUE - 1;

			HttpHeader *h = [[HttpHeader alloc] init];
			h.name        = [[NSString alloc] initWithBytes:cursor
                                              length:name_len
                                            encoding:NSUTF8StringEncoding];
			h.value       = [[NSString alloc] initWithBytes:value_start
                                               length:value_len
                                             encoding:NSUTF8StringEncoding];
			[req.headers addObject:h];
		}
		cursor = next_line + 2;
	}
	return req;
}

// ---------------------------------------------------------------------------
// Connection handling — one pthread per connection
// ---------------------------------------------------------------------------

struct connection_args {
	int   fd;
	void *config_bridged; /* __bridge_retained ServerConfig*, released via __bridge_transfer */
};

static void *handle_connection(void *arg)
{
	struct connection_args *a      = arg;
	int                     fd     = a->fd;
	ServerConfig           *config = (__bridge_transfer ServerConfig *) a->config_bridged;
	free(a);

	struct sockaddr_in peer;
	socklen_t          peer_len                        = sizeof(peer);
	char               client_ip_cstr[INET_ADDRSTRLEN] = "?";

	if (getpeername(fd, (struct sockaddr *) &peer, &peer_len) == 0) {
		inet_ntop(AF_INET, &peer.sin_addr, client_ip_cstr, sizeof(client_ip_cstr));
	}

	NSString *clientIP = [NSString stringWithUTF8String:client_ip_cstr];

	size_t total_len, header_end;
	char  *raw = recv_until_headers_done(fd, &total_len, &header_end);

	if (!raw) {
		close(fd);
		return NULL;
	}

	HttpRequest *req = parse_head(raw, header_end);

	if (!req) {
		LOG_WARN(@"%@: malformed request line/headers", clientIP);
		free(raw);
		close(fd);
		return NULL;
	}

	/* Body: whatever's already past header_end in `raw` is the start of it;
	 * read the rest if Content-Length says there's more. */
	size_t    body_have          = total_len - header_end;
	size_t    content_length     = 0;
	NSString *content_length_hdr = http_get_header(req, @"Content-Length");

	if (content_length_hdr) {
		char cl_buf[32];
		snprintf(cl_buf, sizeof(cl_buf), "%s", [content_length_hdr UTF8String]);
		content_length = (size_t) strtoul(cl_buf, NULL, 10);
	}

	if (content_length > 0) {
		size_t         to_copy  = body_have < content_length ? body_have : content_length;
		NSMutableData *bodyData = [[NSMutableData alloc] initWithCapacity:content_length];
		[bodyData appendBytes:raw + header_end length:to_copy];
		size_t remaining = content_length - to_copy;
		while (remaining > 0) {
			char    chunk[RECV_CHUNK];
			size_t  chunk_size = remaining < sizeof(chunk) ? remaining : sizeof(chunk);
			ssize_t n          = recv(fd, chunk, chunk_size, 0);

			if (n <= 0)
				break;

			[bodyData appendBytes:chunk length:(size_t) n];
			remaining -= (size_t) n;
		}
		req.body = [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding];
	}

	free(raw);

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

	close(fd);
	return NULL;
}

// ---------------------------------------------------------------------------
// Server entry point — blocks forever
// ---------------------------------------------------------------------------

int http_server_run(ServerConfig *config)
{
	int server_fd = socket(AF_INET, SOCK_STREAM, 0);

	if (server_fd < 0) {
		LOG_FATAL(@"http: socket() failed: %s", strerror(errno));
		return 1;
	}

	int yes = 1;
	setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port   = htons(config.port);

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

	if (listen(server_fd, 16) < 0) {
		LOG_FATAL(@"http: listen() failed: %s", strerror(errno));
		close(server_fd);
		return 1;
	}

	LOG_INFO(@"verbatimd listening on http://%@:%u", config.host, config.port);

	for (;;) {
		int client_fd = accept(server_fd, NULL, NULL);

		if (client_fd < 0) {
			if (errno == EINTR)
				continue;
			LOG_WARN(@"http: accept() failed: %s", strerror(errno));
			continue;
		}

		struct connection_args *a = malloc(sizeof(struct connection_args));
		a->fd                     = client_fd;
		a->config_bridged         = (__bridge_retained void *) config;

		pthread_t tid;

		if (pthread_create(&tid, NULL, handle_connection, a) != 0) {
			LOG_ERROR(@"http: pthread_create failed, dropping connection");
			free(a);
			close(client_fd);
			continue;
		}

		pthread_detach(tid);
	}
}
