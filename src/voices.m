/*
 * voices.m — backs GET /voices.
 *
 * Runs `say -v '?'` via NSTask + NSPipe and parses the output into
 * VoiceInfo objects.  No caching — caching is at the JSON layer in
 * routes.m (dispatch_once on first request).
 *
 * `say -v '?'` output format:
 *   Albert              en_US    # Hello!  I am Albert.  I was designed to speak English.
 *   Samantha            en_US    # Hello, I am a British English voice.
 *   ...
 *
 * Parsing strategy:
 *   1. Run `say -v '?'` via NSTask + NSPipe (replaces popen).
 *   2. Split output into lines.
 *   3. For each line, apply a regex: ^(.+)[[:space:]]{2,}([A-Za-z_-]+)[[:space:]]+#
 *      - Group 1: voice name (may have trailing whitespace due to greedy matching)
 *      - Group 2: language code (e.g. "en_US")
 *   4. Trim trailing whitespace from the name.
 *   5. Return an array of VoiceInfo objects.
 *
 * Why NSRegularExpression instead of POSIX regex?
 *   - This is the ObjC codebase — Foundation is the standard.
 *   - NSRegularExpression gives us named ranges and proper NSString integration.
 *   - The old POSIX regex worked but required manual buffer management.
 *
 * Why NSTask instead of popen?
 *   - NSTask is the ObjC way to run external processes.
 *   - It integrates with ARC (no manual fclose/pclose).
 *   - NSPipe gives us proper stdout/stderr separation.
 */

#import "voices.h"

#import <Foundation/Foundation.h>

#import "log.h"

// ── Constants ────────────────────────────────────────────────────────────────

// Initial capacity for the VoiceInfo results array.
// Most macOS systems have 30-80 voices, so 32 avoids the first realloc.
static const NSUInteger kVoicesCapacityInitial = 32;

// ---------------------------------------------------------------------------
// VoiceInfo @implementation
// ---------------------------------------------------------------------------

@implementation VoiceInfo

// Simple data container — custom init only for logging.
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

// ── runSayVoiceList ──────────────────────────────────────────────────────────
// Runs `say -v '?'` via NSTask + NSPipe and returns the full stdout output.
//
// The `say` command is macOS's built-in text-to-speech utility.
// With `-v '?'`, it lists all available voices and their properties.
//
// Flow:
//   1. Create NSTask with executable /usr/bin/say
//   2. Set arguments to ["-v", "?"]
//   3. Pipe stdout and stderr (stderr is discarded)
//   4. Launch the task, wait for it to exit
//   5. Read all stdout data via NSPipe
//   6. Convert to NSString and return
//
// Returns nil on failure (launch error or empty output).
+ (NSString *)runSayVoiceList
{
	LOG_DEBUG(@"voices: launching `say -v '?'`");

	// Configure the task
	NSTask *task        = [[NSTask alloc] init];
	task.executableURL  = [NSURL fileURLWithPath:@"/usr/bin/say"];
	task.arguments      = @[@"-v", @"?"];
	task.standardOutput = [NSPipe pipe];  // Capture stdout
	task.standardError  = [NSPipe pipe];  // Discard stderr

	// Launch the task
	NSError *error = nil;
	[task launchAndReturnError:&error];
	if (error) {
		LOG_ERROR(@"voices: NSTask launch failed: %@", error.localizedDescription);
		return nil;
	}
	LOG_TRACE(@"voices: NSTask launched successfully");

	// Wait for the task to finish
	[task waitUntilExit];

	// Read all stdout output
	NSData *outputData = [[task.standardOutput fileHandleForReading] readDataToEndOfFile];
	int     status     = task.terminationStatus;
	LOG_DEBUG(@"voices: process exited status=%d, %lu bytes stdout",
	          status,
	          (unsigned long) outputData.length);

	// Check for empty output
	if (!outputData || outputData.length == 0) {
		return nil;
	}

	// Convert raw bytes to a string
	NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
	return output;
}

// ── parseVoiceList: ──────────────────────────────────────────────────────────
// Parses `say -v '?'` output into VoiceInfo objects.
//
// Each line in the output looks like:
//   "Albert              en_US    # Hello!  I am Albert."
//
// The regex ^(.+)[[:space:]]{2,}([A-Za-z_-]+)[[:space:]]+# captures:
//   Group 1: voice name (e.g. "Albert              ")
//   Group 2: language code (e.g. "en_US")
//
// The name has trailing whitespace due to POSIX's greedy matching,
// which we trim with stringByTrimmingCharactersInSet:.
//
// Returns an array of VoiceInfo objects.
+ (NSArray<VoiceInfo *> *)parseVoiceList:(NSString *)output
{
	LOG_TRACE(@"voices: parsing voice list output");

	// Compile the regex
	NSError             *regexError = nil;
	NSString            *pattern    = @"^(.+)[[:space:]]{2,}([A-Za-z_-]+)[[:space:]]+#";
	NSRegularExpression *re         = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:0
                                                                          error:&regexError];
	if (!re) {
		LOG_ERROR(@"voices: failed to compile regex: %@", regexError.localizedDescription);
		return @[];
	}

	// Allocate the results array with initial capacity
	NSMutableArray<VoiceInfo *> *results = [NSMutableArray arrayWithCapacity:kVoicesCapacityInitial];

	// Split output into lines and process each one
	NSArray<NSString *> *lines        = [output componentsSeparatedByString:@"\n"];
	int                  linesChecked = 0, linesMatched = 0;

	for (NSString *line in lines) {
		// Skip empty lines and absurdly long lines (safety)
		if (line.length == 0 || line.length >= 512)
			continue;

		linesChecked++;

		// Try to match the regex against this line
		NSTextCheckingResult *match = [re firstMatchInString:line
		                                             options:0
		                                               range:NSMakeRange(0, line.length)];
		if (match && match.numberOfRanges >= 3) {
			NSRange nameRange = [match rangeAtIndex:1];
			NSRange langRange = [match rangeAtIndex:2];

			// Extract the voice name and trim trailing whitespace
			NSString *name = [line substringWithRange:nameRange];
			name           = [name
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

			// Extract the language code
			NSString *language = [line substringWithRange:langRange];

			// Create a VoiceInfo object and add it to the results
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
	return [results copy];  // Return an immutable copy
}

// ---------------------------------------------------------------------------
// Public API — always runs `say -v '?'` fresh, no caching.
// Caching is handled at the JSON layer in routes.m.
// ---------------------------------------------------------------------------

// Runs `say -v '?'` and parses the output into VoiceInfo objects.
// Always runs fresh — no caching.  Caching is in routes.m.
+ (NSArray<VoiceInfo *> *)voicesList
{
	LOG_DEBUG(@"voices: shelling out to `say -v '?'`");

	// Run `say -v '?'` and get the stdout output
	NSString *output = [self runSayVoiceList];
	if (!output) {
		LOG_WARN(@"voices: runSayVoiceList returned nil");
		return @[];
	}

	// Parse the output into VoiceInfo objects
	LOG_TRACE(@"voices: parsing output (%lu bytes)", (unsigned long) output.length);
	NSArray<VoiceInfo *> *voices = [self parseVoiceList:output];

	LOG_DEBUG(@"voices: returning %lu voices", (unsigned long) voices.count);
	return voices;
}

@end
