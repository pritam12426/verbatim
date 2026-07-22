/*
 * voices.h — backs GET /voices.
 *
 * Runs `say -v '?'` (macOS's built-in voice listing command) and
 * parses the output into VoiceInfo objects.
 *
 * Caching strategy:
 *   This layer does NOT cache — every call to +voicesList runs
 *   `say -v '?'` fresh.  Caching is handled at the JSON layer in
 *   routes.m via dispatch_once, which caches the serialized JSON
 *   bytes for the process lifetime.
 *
 * Why not cache here?
 *   - The JSON cache in routes.m is simpler (raw bytes, no parsing).
 *   - voices.m stays focused on parsing, not caching policy.
 *   - If we ever need voice list refresh, we just remove the cache.
 *
 * VoiceInfo — a single voice entry from `say -v '?'`.
 *   name     — display name (e.g. "Albert", "Samantha")
 *   language — language code (e.g. "en_US", "fr_FR")
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// VoiceInfo — a single voice entry from `say -v '?'`.
@interface                           VoiceInfo : NSObject
@property(nonatomic, copy) NSString *name;      // Display name (e.g. "Albert")
@property(nonatomic, copy) NSString *language;  // Language code (e.g. "en_US")
@end

// Voices — runs `say -v '?'` and parses the output.
@interface Voices : NSObject

// Runs `say -v '?'` via NSTask and parses the output into VoiceInfo objects.
// Always runs fresh (no caching).  Caching is in routes.m.
+ (NSArray<VoiceInfo *> *)voicesList;

@end

NS_ASSUME_NONNULL_END
