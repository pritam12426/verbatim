#ifndef _VOICES_H_
#define _VOICES_H_


#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ---------------------------------------------------------------------------
// VoiceInfo — a single voice entry from `say -v '?'`
// ---------------------------------------------------------------------------

@interface                           VoiceInfo : NSObject
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *language;
@end

// ---------------------------------------------------------------------------
// voicesList — backed by GET /voices
//
// Shells out to `say -v '?'` on the first call, then returns the cached
// result for the process lifetime.
// ---------------------------------------------------------------------------

NSArray<VoiceInfo *> *voicesList(void);

NS_ASSUME_NONNULL_END


#endif  // _VOICES_H_
