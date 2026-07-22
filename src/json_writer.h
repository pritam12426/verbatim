/*
 * json_writer.h — the only "JSON library" this project needs.
 *
 * Wraps NSJSONSerialization in a simple ObjC class interface.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JSONWriter : NSObject

// Serializes a JSON-compatible Foundation object graph into NSData.
// Returns nil on failure (logs error).
+ (nullable NSData *)serialize:(id)object;

@end

NS_ASSUME_NONNULL_END
