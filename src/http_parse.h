/*
 * http_parse.h — HTTP request parsing class methods
 */

#import "http_server.h"

NS_ASSUME_NONNULL_BEGIN

@interface HttpParse : NSObject

// Reads from fd until \r\n\r\n is found.  Returns an NSData buffer
// with *totalLen set to bytes received and *headerEnd set to the offset
// past the blank line.  Returns nil on connection close or error.
+ (NSData *_Nullable)recvUntilHeadersDoneWithFD:(int)fd
                                       totalLen:(NSUInteger *)totalLen
                                      headerEnd:(NSUInteger *)headerEnd;

// Parses the request line + headers from the first headerEnd bytes of data
// and returns a fully-populated HttpRequest object.  Does NOT read the body.
+ (HttpRequest *_Nullable)parseHeadWithData:(NSData *)data headerEnd:(NSUInteger)headerEnd;

@end

NS_ASSUME_NONNULL_END
