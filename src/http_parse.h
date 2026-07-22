/*
 * http_parse.h — HTTP request parsing class methods.
 *
 * Self-contained "read half" of the HTTP layer.  Takes a raw socket
 * file descriptor and returns a parsed HttpRequest object.
 *
 * No response logic — purely input-side.  Depends only on POSIX
 * recv() and Foundation (NSData, NSString, NSScanner).
 *
 * Usage (called from http_server.m):
 *   NSData *raw = [HttpParse recvUntilHeadersDoneWithFD:fd
 *                                             totalLen:&totalLen
 *                                            headerEnd:&headerEnd];
 *   HttpRequest *req = [HttpParse parseHeadWithData:raw headerEnd:headerEnd];
 */

#import "http_server.h"

NS_ASSUME_NONNULL_BEGIN

// HttpParse — request parsing class methods.
// All methods are class-level (no instances created).
@interface HttpParse : NSObject

// Reads from fd until \r\n\r\n is found.
//
// Returns an NSData buffer containing all received bytes, with:
//   *totalLen  — total bytes received
//   *headerEnd — offset past the blank line (\r\n\r\n)
//
// Returns nil on connection close or error.
//
// The returned data includes both headers AND any bytes received
// after the blank line (which are the start of the body).  The
// caller (http_server.m) uses headerEnd to split the body from
// the headers and reads any remaining body bytes via recv().
+ (NSData *_Nullable)recvUntilHeadersDoneWithFD:(int)fd
                                       totalLen:(NSUInteger *)totalLen
                                      headerEnd:(NSUInteger *)headerEnd;

// Parses the request line + headers from the first headerEnd bytes
// of data and returns a fully-populated HttpRequest object.
//
// Does NOT read the body — that's the caller's responsibility.
//
// Returns nil if the request line is malformed (not "METHOD PATH VERSION")
// or if the data cannot be decoded as UTF-8.
+ (HttpRequest *_Nullable)parseHeadWithData:(NSData *)data headerEnd:(NSUInteger)headerEnd;

@end

NS_ASSUME_NONNULL_END
