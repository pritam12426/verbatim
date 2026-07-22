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

const char *http_get_header(const HttpRequest *req, const char *name)
{
	for (int i = 0; i < req->header_count; i++) {
		if (strcasecmp(req->headers[i].name, name) == 0) {
			return req->headers[i].value;
		}
	}
	return NULL;
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

/* ---- request parsing ---- */

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

/* Parses the request line + headers from buf[0..header_end). Does NOT read
 * the body — caller does that separately once Content-Length is known. */
static int parse_head(HttpRequest *req, const char *buf, size_t header_end)
{
	memset(req, 0, sizeof(*req));

	const char *line_end = strstr(buf, "\r\n");
	if (!line_end || line_end - buf >= (long) header_end)
		return -1;

	char method[8], path[HTTP_MAX_PATH], version[16];
	int  matched = sscanf(buf, "%7s %511s %15s", method, path, version);
	if (matched != 3)
		return -1;
	snprintf(req->method, sizeof(req->method), "%s", method);
	snprintf(req->path, sizeof(req->path), "%s", path);

	const char *cursor = line_end + 2;
	while (cursor < buf + header_end && req->header_count < HTTP_MAX_HEADERS) {
		const char *next_line = strstr(cursor, "\r\n");
		if (!next_line || next_line == cursor)
			break; /* blank line = end of headers */

		const char *colon = memchr(cursor, ':', (size_t) (next_line - cursor));
		if (colon) {
			size_t name_len = (size_t) (colon - cursor);
			if (name_len >= HTTP_MAX_HEADER_NAME) {
				name_len = HTTP_MAX_HEADER_NAME - 1;
			}

			const char *value_start = colon + 1;
			while (value_start < next_line && *value_start == ' ') {
				value_start++;
			}
			size_t value_len = (size_t) (next_line - value_start);
			if (value_len >= HTTP_MAX_HEADER_VALUE) {
				value_len = HTTP_MAX_HEADER_VALUE - 1;
			}

			HttpHeader *h = &req->headers[req->header_count];
			memcpy(h->name, cursor, name_len);
			h->name[name_len] = '\0';
			memcpy(h->value, value_start, value_len);
			h->value[value_len] = '\0';
			req->header_count++;
		}
		cursor = next_line + 2;
	}
	return 0;
}

static void free_request(HttpRequest *req)
{
	free(req->body);
	req->body = NULL;
}

struct connection_args {
	int                 fd;
	const ServerConfig *config;
};

static void *handle_connection(void *arg)
{
	struct connection_args *a      = arg;
	int                     fd     = a->fd;
	const ServerConfig     *config = a->config;
	free(a);

	struct sockaddr_in peer;
	socklen_t          peer_len                   = sizeof(peer);
	char               client_ip[INET_ADDRSTRLEN] = "?";

	if (getpeername(fd, (struct sockaddr *) &peer, &peer_len) == 0) {
		inet_ntop(AF_INET, &peer.sin_addr, client_ip, sizeof(client_ip));
	}

	size_t total_len, header_end;
	char  *raw = recv_until_headers_done(fd, &total_len, &header_end);

	if (!raw) {
		close(fd);
		return NULL;
	}

	HttpRequest req;

	if (parse_head(&req, raw, header_end) != 0) {
		LOG_WARN(@"%s: malformed request line/headers", client_ip);
		free(raw);
		close(fd);
		return NULL;
	}

	/* Body: whatever's already past header_end in `raw` is the start of it;
	 * read the rest if Content-Length says there's more. */
	size_t      body_have          = total_len - header_end;
	const char *content_length_hdr = http_get_header(&req, "Content-Length");
	size_t content_length = content_length_hdr ? (size_t) strtoul(content_length_hdr, NULL, 10) : 0;

	if (content_length > 0) {
		req.body      = malloc(content_length + 1);
		size_t copied = body_have < content_length ? body_have : content_length;
		memcpy(req.body, raw + header_end, copied);
		size_t remaining = content_length - copied;
		while (remaining > 0) {
			ssize_t n = recv(fd, req.body + copied, remaining, 0);

			if (n <= 0) {
				break;
			}

			copied    += (size_t) n;
			remaining -= (size_t) n;
		}
		req.body[copied] = '\0';
		req.body_len     = copied;
	}
	free(raw);

	LOG_INFO(@"%s %s %s", client_ip, req.method, req.path);

	if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/") == 0) {
		route_speak(fd, &req, config, client_ip);
	} else if (strcmp(req.method, "POST") == 0 && strcmp(req.path, "/stop") == 0) {
		route_stop(fd, &req, client_ip);
	} else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/status") == 0) {
		route_status(fd, &req, client_ip);
	} else if (strcmp(req.method, "GET") == 0 && strcmp(req.path, "/voices") == 0) {
		route_voices(fd, &req, client_ip);
	} else {
		route_not_found(fd);
	}

	free_request(&req);
	close(fd);
	return NULL;
}

int http_server_run(const ServerConfig *config)
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
	addr.sin_port   = htons(config->port);
	if (inet_pton(AF_INET, config->host, &addr.sin_addr) != 1) {
		LOG_FATAL(@"http: invalid host '%s'", config->host);
		close(server_fd);
		return 1;
	}

	if (bind(server_fd, (struct sockaddr *) &addr, sizeof(addr)) < 0) {
		LOG_FATAL(@"http: bind(%s:%u) failed: %s", config->host, config->port, strerror(errno));
		close(server_fd);
		return 1;
	}

	if (listen(server_fd, 16) < 0) {
		LOG_FATAL(@"http: listen() failed: %s", strerror(errno));
		close(server_fd);
		return 1;
	}

	LOG_INFO(@"verbatimd listening on http://%s:%u", config->host, config->port);

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
		a->config                 = config;

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
