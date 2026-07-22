/*
 * routes.h — top-level route dispatch
 */

#import "http_server.h"

NS_ASSUME_NONNULL_BEGIN

@interface Routes : NSObject

+ (void)stopWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP;
+ (void)statusWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP;
+ (void)voicesWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP;
+ (void)notFoundWithFD:(int)fd;

@end

NS_ASSUME_NONNULL_END
