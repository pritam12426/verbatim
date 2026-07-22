/*
 * voices.h — backs GET /voices
 *
 * Shells out to `say -v '?'` every call.  Caching is handled at the
 * serialized-JSON layer in routes.m (dispatch_once on first request).
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface                           VoiceInfo : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *language;
@end

@interface Voices : NSObject

+ (NSArray<VoiceInfo *> *)voicesList;

@end

NS_ASSUME_NONNULL_END
