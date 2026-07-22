/*
 * http_server.h — core data types and server entry point
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// Data types
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
// Server entry point
// ---------------------------------------------------------------------------

@interface HttpServer : NSObject

// Blocks forever, accepting connections and spawning a thread per connection.
// Intended to be called from a dedicated background thread — see main.m.
+ (int)runWithConfig:(ServerConfig *)config;

@end

NS_ASSUME_NONNULL_END
