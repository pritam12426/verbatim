/*
 * http_server.h — core data types and server entry point.
 *
 * This header defines the three data types shared across the HTTP layer:
 *
 *   HttpHeader  — a single "Name: Value" header pair.
 *   HttpRequest — a parsed HTTP request (method, path, headers, body).
 *   ServerConfig — server configuration (host, port, default rate).
 *
 * And the server entry point:
 *
 *   HttpServer  — class method that runs the accept loop forever.
 *
 * Relationship to other files:
 *   - http_parse.h   — request parsing (reads from socket, fills HttpRequest)
 *   - http_response.h — response writing (writes to socket from HttpRequest)
 *   - routes.h       — route dispatch (consumes HttpRequest, writes response)
 *   - route_speak.h  — POST / handler (the most complex route)
 *
 * Thread model:
 *   - HttpServer.runWithConfig: runs on a dedicated background thread
 *     (spawned by main.m).  It blocks in accept() forever.
 *   - Each accepted connection gets its own NSThread, which calls
 *     handleConnectionWithFD:config:.
 *   - The main thread runs CFRunLoopRun() for speech delegate callbacks.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── Data types ───────────────────────────────────────────────────────────────

// HttpHeader — a single HTTP header name-value pair.
// Part of HttpRequest.headers array.
@interface                           HttpHeader : NSObject
@property(nonatomic, copy) NSString *name;   // Header name (e.g. "Content-Type")
@property(nonatomic, copy) NSString *value;  // Header value (e.g. "application/json")
@end

// HttpRequest — a fully-parsed HTTP request.
// Created by HttpParse.parseHeadWithData:headerEnd: and consumed by
// route handlers (Routes, Routes (Speak)).
@interface                           HttpRequest : NSObject
@property(nonatomic, copy) NSString *method;  // "GET", "POST", etc.
@property(nonatomic, copy) NSString *path;    // "/", "/stop", "/voices", etc.
@property(nonatomic, strong)
    NSMutableArray<HttpHeader *>              *headers;  // All headers, case-sensitive names
@property(nonatomic, copy, nullable) NSString *body;     // Request body (POST only), nil for GET
@end

// ServerConfig — server configuration passed from main.m to HttpServer.
// Heap-allocated so it outlives main() for as long as the server thread runs.
@interface                           ServerConfig : NSObject
@property(nonatomic, copy) NSString *host;         // Bind address (e.g. "127.0.0.1")
@property(nonatomic) unsigned short  port;         // Listen port (e.g. 5959)
@property(nonatomic) float           defaultRate;  // Default TTS rate in WPM (e.g. 175)
@end

// ── Server entry point ───────────────────────────────────────────────────────

// HttpServer — the HTTP server.
// All methods are class methods (no instances created).
@interface HttpServer : NSObject

// Blocks forever, accepting connections and spawning a thread per connection.
// Intended to be called from a dedicated background thread — see main.m.
// Returns non-zero on fatal error (socket/bind/listen failure).
+ (int)runWithConfig:(ServerConfig *)config;

@end

NS_ASSUME_NONNULL_END
