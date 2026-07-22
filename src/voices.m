/*
 * voices.m — backs GET /voices.
 *
 * Matches lines like: "Albert              en_US    # Hello! ..."
 * Uses NSRegularExpression (the ObjC equivalent of POSIX ERE) and
 * NSTask + NSPipe to run `say -v '?'` instead of popen().
 */

#import "voices.h"

#import <Foundation/Foundation.h>

#import "log.h"

static const NSUInteger kVoicesCapacityInitial = 32;

// ---------------------------------------------------------------------------
// VoiceInfo @implementation
// ---------------------------------------------------------------------------

@implementation VoiceInfo
- (instancetype)init
{
	self = [super init];
	if (self) {
		LOG_TRACE(@"voices: VoiceInfo created");
	}
	return self;
}
@end

// ---------------------------------------------------------------------------
// Voices — private helpers
// ---------------------------------------------------------------------------

@implementation Voices

// Runs `say -v '?'` via NSTask + NSPipe and returns the full stdout output.
+ (NSString *)runSayVoiceList
{
	LOG_DEBUG(@"voices: launching `say -v '?'`");

	NSTask *task        = [[NSTask alloc] init];
	task.executableURL  = [NSURL fileURLWithPath:@"/usr/bin/say"];
	task.arguments      = @[@"-v", @"?"];
	task.standardOutput = [NSPipe pipe];
	task.standardError  = [NSPipe pipe];

	NSError *error = nil;
	[task launchAndReturnError:&error];
	if (error) {
		LOG_ERROR(@"voices: NSTask launch failed: %@", error.localizedDescription);
		return nil;
	}
	LOG_TRACE(@"voices: NSTask launched successfully");

	[task waitUntilExit];

	NSData *outputData = [[task.standardOutput fileHandleForReading] readDataToEndOfFile];
	int     status     = task.terminationStatus;
	LOG_DEBUG(@"voices: process exited status=%d, %lu bytes stdout",
	          status,
	          (unsigned long) outputData.length);

	if (!outputData || outputData.length == 0) {
		return nil;
	}

	NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
	return output;
}

// Parses `say -v '?'` output into VoiceInfo objects.
+ (NSArray<VoiceInfo *> *)parseVoiceList:(NSString *)output
{
	LOG_TRACE(@"voices: parsing voice list output");

	NSError             *regexError = nil;
	NSString            *pattern    = @"^(.+)[[:space:]]{2,}([A-Za-z_-]+)[[:space:]]+#";
	NSRegularExpression *re         = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:0
                                                                          error:&regexError];
	if (!re) {
		LOG_ERROR(@"voices: failed to compile regex: %@", regexError.localizedDescription);
		return @[];
	}

	NSMutableArray<VoiceInfo *> *results = [NSMutableArray arrayWithCapacity:kVoicesCapacityInitial];

	NSArray<NSString *> *lines        = [output componentsSeparatedByString:@"\n"];
	int                  linesChecked = 0, linesMatched = 0;

	for (NSString *line in lines) {
		if (line.length == 0 || line.length >= 512)
			continue;

		linesChecked++;

		NSTextCheckingResult *match = [re firstMatchInString:line
		                                             options:0
		                                               range:NSMakeRange(0, line.length)];
		if (match && match.numberOfRanges >= 3) {
			NSRange nameRange = [match rangeAtIndex:1];
			NSRange langRange = [match rangeAtIndex:2];

			NSString *name = [line substringWithRange:nameRange];
			// Trim trailing whitespace from name (POSIX greedy matching pulls it in)
			name           = [name
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

			NSString *language = [line substringWithRange:langRange];

			VoiceInfo *v = [[VoiceInfo alloc] init];
			v.name       = name;
			v.language   = language;
			[results addObject:v];
			linesMatched++;
		}
	}

	LOG_DEBUG(@"voices: parse complete — %d lines checked, %d matched, %lu results",
	          linesChecked,
	          linesMatched,
	          (unsigned long) results.count);
	return [results copy];
}

// ---------------------------------------------------------------------------
// Public API — always runs `say -v '?'` fresh, no caching.
// Caching is handled at the JSON layer in routes.m.
// ---------------------------------------------------------------------------

+ (NSArray<VoiceInfo *> *)voicesList
{
	LOG_DEBUG(@"voices: shelling out to `say -v '?'`");
	NSString *output = [self runSayVoiceList];
	if (!output) {
		LOG_WARN(@"voices: runSayVoiceList returned nil");
		return @[];
	}

	LOG_TRACE(@"voices: parsing output (%lu bytes)", (unsigned long) output.length);
	NSArray<VoiceInfo *> *voices = [self parseVoiceList:output];

	LOG_DEBUG(@"voices: returning %lu voices", (unsigned long) voices.count);
	return voices;
}

@end
