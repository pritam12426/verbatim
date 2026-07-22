/*
 * route_speak.h — POST / speak endpoint category
 */

#import "routes.h"

NS_ASSUME_NONNULL_BEGIN

@interface Routes (Speak)

+ (void)speakWithFD:(int)fd
            request:(HttpRequest *)req
             config:(ServerConfig *)config
           clientIP:(NSString *)clientIP;

@end

NS_ASSUME_NONNULL_END
