#ifndef _VERBATIM_HTTP_SERVER_H_
#define _VERBATIM_HTTP_SERVER_H_


#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#define HTTP_MAX_HEADERS      32
#define HTTP_MAX_HEADER_NAME  64
#define HTTP_MAX_HEADER_VALUE 256
#define HTTP_MAX_PATH         512

// ---------------------------------------------------------------------------
// Data types — formerly C structs, now ObjC objects
// ---------------------------------------------------------------------------

@interface                           HttpHeader : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *value;
@end

@interface                                                 HttpRequest : NSObject
@property(nonatomic, copy) NSString                       *method;
@property(nonatomic, copy) NSString                       *path;
@property(nonatomic, strong) NSMutableArray<HttpHeader *> *headers;
@property(nonatomic, copy, nullable) NSString             *body;
@end

@interface                           ServerConfig : NSObject
@property(nonatomic, copy) NSString *host;
@property(nonatomic) unsigned short  port;
@property(nonatomic) float           defaultRate;
@end

// ---------------------------------------------------------------------------
// HTTP utilities (C functions — called from routes.m, http_server.m)
// ---------------------------------------------------------------------------

// Case-insensitive header lookup, matching HTTP semantics.
NSString *_Nullable http_get_header(HttpRequest *req, NSString *name);

// Writes a complete, non-streamed HTTP response with Content-Length.
void http_send_response(int         fd,
                        int         status_code,
                        const char *status_text,
                        const char *content_type,
                        const char *body,
                        size_t      body_len);

// Chunked streaming response (POST / with ndjson=true).
void http_begin_chunked_response(int fd, const char *content_type);
void http_write_chunk(int fd, const char *data, size_t len);
void http_end_chunks(int fd);

// Blocks forever, accepting connections and spawning a thread per connection.
// Intended to be called from a dedicated background thread — see main.m.
int http_server_run(ServerConfig *config);

NS_ASSUME_NONNULL_END


#endif  // VERBATIM_HTTP_SERVER_H
