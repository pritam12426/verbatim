NS_ASSUME_NONNULL_BEGIN

#include <stddef.h>

#define HTTP_MAX_HEADERS      32
#define HTTP_MAX_HEADER_NAME  64
#define HTTP_MAX_HEADER_VALUE 256
#define HTTP_MAX_PATH         512

typedef struct {
	char name[HTTP_MAX_HEADER_NAME];
	char value[HTTP_MAX_HEADER_VALUE];
} HttpHeader;

typedef struct {
	char       method[8]; /* "GET", "POST", ... */
	char       path[HTTP_MAX_PATH];
	HttpHeader headers[HTTP_MAX_HEADERS];
	int        header_count;
	char      *body; /* malloc'd, may be NULL if no body */
	size_t     body_len;
} HttpRequest;

typedef struct {
	const char    *host;
	unsigned short port;
	float          default_rate;
} ServerConfig;

/* Case-insensitive header lookup, matching HTTP semantics (and FlyingFox's
 * HTTPHeader equality, which the Swift version relied on for the same
 * TTS-Voice/TTS-Speed/ndjson headers). Returns NULL if not present. */
const char *http_get_header(const HttpRequest *req, const char *name);

/* Writes a complete, non-streamed HTTP response with a Content-Length
 * header — used for /stop, /status, /voices, and error responses. */
void http_send_response(int         fd,
                        int         status_code,
                        const char *status_text,
                        const char *content_type,
                        const char *body,
                        size_t      body_len);

/* Writes the status line + headers for a CHUNKED response and returns —
 * caller then calls http_write_chunk() repeatedly, followed by
 * http_end_chunks(). Used only by POST / when ndjson=true. */
void http_begin_chunked_response(int fd, const char *content_type);
void http_write_chunk(int fd, const char *data, size_t len);
void http_end_chunks(int fd);

/* Blocks forever, accepting connections and spawning a thread per
 * connection. Returns non-zero on fatal startup error (e.g. bind failed).
 * Intended to be called from a dedicated background thread — see main.m,
 * which reserves the real main thread for CFRunLoopRun(). */
int http_server_run(const ServerConfig *config);

NS_ASSUME_NONNULL_END
