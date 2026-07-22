#ifndef _ROUTES_H_
#define _ROUTES_H_


#import "http_server.h"

NS_ASSUME_NONNULL_BEGIN

@interface Routes : NSObject

+ (void)speakWithFD:(int)fd
            request:(HttpRequest *)req
             config:(ServerConfig *)config
           clientIP:(NSString *)clientIP;

+ (void)stopWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP;

+ (void)statusWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP;

+ (void)voicesWithFD:(int)fd request:(HttpRequest *)req clientIP:(NSString *)clientIP;

+ (void)notFoundWithFD:(int)fd;

@end

NS_ASSUME_NONNULL_END


#endif  // _ROUTES_H_
