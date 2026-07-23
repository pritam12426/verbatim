/*
 * log.m — Thread-safe logging implementation for Objective-C.
 *
 * See log.h for the public API (LOG_* macros, LogLevel enum, +init:).
 *
 * Thread-safety model:
 *   All mutable state (_logLevel, _useColor, _initialized) and the
 *   actual write to stderr are protected by @synchronized(self) on
 *   the Logger class object.  This means every LOG_* call takes a
 *   brief lock, serialising output from concurrent threads so lines
 *   never interleave.  The lock is uncontended in the common case
 *   (single-threaded HTTP request handling), so overhead is negligible.
 *
 * Output destination:
 *   All output goes to stderr via NSFileHandle.  We use NSFileHandle
 *   instead of fprintf because:
 *     1. It's the idiomatic Objective-C way to write to file descriptors.
 *     2. It handles UTF-8 encoding correctly without manual conversion.
 *     3. It avoids C stdio buffering issues (fflush, buffer overflow).
 *
 * Colour detection:
 *   On +init:, we call isatty(fileno(stderr)) to determine whether
 *   stderr is a terminal.  If it is, ANSI escape sequences are emitted
 *   for coloured output.  If stderr is piped/redirected, colour is
 *   suppressed to avoid garbled output in log files.
 */

#import "log.h"

#import <Foundation/Foundation.h>

// ── ANSI colour escape sequences ─────────────────────────────────────────────
// These are the standard ANSI x3.64 colour codes.  They are only
// emitted when _useColor is YES (stderr is a TTY).
static NSString *const kColorReset       = @"\x1b[0m";     // Reset all attributes
static NSString *const kColorBoldRed     = @"\x1b[1;31m";  // Bold + red (ERROR)
static NSString *const kColorBoldGreen   = @"\x1b[1;32m";  // Bold + green (INFO)
static NSString *const kColorBoldYellow  = @"\x1b[1;33m";  // Bold + yellow (WARN)
static NSString *const kColorBoldBlue    = @"\x1b[1;34m";  // Bold + blue (FATAL, UNKWN)
static NSString *const kColorBoldMagenta = @"\x1b[1;35m";  // Bold + magenta (TRACE)
static NSString *const kColorBoldCyan    = @"\x1b[1;36m";  // Bold + cyan (DEBUG)
static NSString *const kColorDim         = @"\x1b[2m";     // Dim text (timestamps, source loc)

// ── Logger module-level state ────────────────────────────────────────────────
// All mutable state is protected by @synchronized(self) on the Logger
// class object.  Since +record: always acquires this lock (to prevent
// interleaved output), a simple @synchronized block is cleaner than
// manual NSLock operations.
//
// _logLevel    — minimum severity; messages above this are suppressed
// _useColor    — YES if stderr is a TTY and ANSI codes should be emitted
// _initialized — YES after +init: has been called; +record: checks this
//                and drops messages (with an error) if +init: was skipped
static LogLevel _logLevel    = LogLevelInfo;  // sensible default before +init:
static BOOL     _useColor    = NO;            // assume no colour until +init: detects TTY
static BOOL     _initialized = NO;            // guards against use before +init:

@implementation Logger

// ── Internal helpers (called with lock already held) ─────────────────────────
// These methods are only called from within @synchronized(self) blocks,
// so they don't need their own locking.

// Returns the plain-text label for a log level, padded to 5 chars
// for alignment.  The trailing space in "WARN " and "INFO " ensures
// all labels are exactly 5 characters wide when printed in brackets.
+ (NSString *)levelLabel:(LogLevel)level
{
	switch (level) {
	case LogLevelFatal:
		return @"[FATAL]";
	case LogLevelError:
		return @"[ERROR]";
	case LogLevelWarn:
		return @"[WARN ]";
	case LogLevelInfo:
		return @"[INFO ]";
	case LogLevelDebug:
		return @"[DEBUG]";
	case LogLevelTrace:
		return @"[TRACE]";
	default:
		return @"[UNKWN]";
	}
}

// Returns the ANSI-coloured label for a log level.  Each level gets
// a distinct colour so that scanning terminal output visually is easy:
//   FATAL  — blue (stands out as a crash-level event)
//   ERROR  — red (failures requiring attention)
//   WARN   — yellow (suspicious but non-fatal)
//   INFO   — green (normal lifecycle events)
//   DEBUG  — cyan (developer diagnostics)
//   TRACE  — magenta (extremely verbose)
+ (NSString *)levelLabelColored:(LogLevel)level
{
	switch (level) {
	case LogLevelFatal:
		return [NSString stringWithFormat:@"\U0001F480 %@[FATAL]%@ ", kColorBoldBlue, kColorReset];
	case LogLevelError:
		return [NSString stringWithFormat:@"\U0001F6A8 %@[ERROR]%@ ", kColorBoldRed, kColorReset];
	case LogLevelWarn:
		return [NSString stringWithFormat:@"\u26A0\uFE0F  %@[WARN ]%@ ", kColorBoldYellow, kColorReset];
	case LogLevelInfo:
		return [NSString stringWithFormat:@"\u2139\uFE0F  %@[INFO ]%@ ", kColorBoldGreen, kColorReset];
	case LogLevelDebug:
		return [NSString stringWithFormat:@"\U0001F6E0\uFE0F  %@[DEBUG]%@ ", kColorBoldCyan, kColorReset];
	case LogLevelTrace:
		return [NSString stringWithFormat:@"\U0001F52C %@[TRACE]%@ ", kColorBoldMagenta, kColorReset];
	default:
		return [NSString stringWithFormat:@"%@[UNKWN]%@ ", kColorBoldBlue, kColorReset];
	}
}

#ifdef LOG_SHOW_TIME_STAMP

// Returns a microsecond-precision timestamp string: "HH:MM:SS.uuuuuu"
//
// We use NSDate/NSTimeInterval rather than POSIX clock_gettime()
// because this is the ObjC codebase and we want Foundation-only
// dependencies.  The split into seconds + microseconds gives us
// microsecond precision without floating-point formatting issues.
+ (NSString *)logTimeStamp
{
	// Get current time as a floating-point interval since Unix epoch
	NSTimeInterval interval = [[NSDate date] timeIntervalSince1970];

	// Split into integer seconds and fractional microseconds
	long long seconds = (long long) interval;
	int       us      = (int) ((interval - (double) seconds) * 1000000.0);

	// Format the time-of-day portion as HH:mm:ss
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat       = @"HH:mm:ss";
	formatter.timeZone         = [NSTimeZone localTimeZone];

	NSDate   *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval) seconds];
	NSString *time = [formatter stringFromDate:date];

	// Combine: "14:32:05.123456"
	return [NSString stringWithFormat:@"%@.%06d", time, us];
}

#endif  // LOG_SHOW_TIME_STAMP

// ── Public API ───────────────────────────────────────────────────────────────

// Initialise the logger.  Thread-safe; may be called multiple times
// (e.g. once at startup with a default, then again after argv parsing
// with the user-specified level).
//
// Side effects:
//   1. Sets _logLevel to the requested severity threshold.
//   2. Detects whether stderr is a TTY (isatty) and sets _useColor.
//   3. Sets _initialized = YES, enabling +record: to actually emit.
+ (void)init:(LogLevel)level
{
	@synchronized(self) {
		_initialized = YES;
		_useColor    = isatty(fileno(stderr)) ? YES : NO;
		_logLevel    = level;
	}
}

// Change the minimum log level at runtime.  Thread-safe.
// Messages below the new level are suppressed immediately.
+ (void)setLevel:(LogLevel)level
{
	@synchronized(self) {
		_logLevel = level;
	}
}

// Get the current minimum log level.  Thread-safe.
+ (LogLevel)getLevel
{
	@synchronized(self) {
		return _logLevel;
	}
}

// Check whether ANSI colour is currently enabled.
+ (BOOL)useColor
{
	@synchronized(self) {
		return _useColor;
	}
}

// Log strerror(errno) as a separate LOG_ERROR line.
// Saves errno immediately (in case another call modifies it),
// converts it to a human-readable string via strerror(), and
// writes it directly to stderr (bypassing the normal +record:
// path to avoid re-entrancy issues with the lock).
+ (void)logErrno
{
	int         savedErrno = errno;  // Save errno immediately
	const char *msg        = strerror(savedErrno);
	NSString   *message    = [NSString stringWithFormat:@"[LOG] errno=%d: %s", savedErrno, msg];

	NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
	[stderrHandle writeData:[message dataUsingEncoding:NSUTF8StringEncoding]];
	[stderrHandle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

// Core logging function: formats and writes a log message.
// Called by the LOG_* macros. Thread-safe via @synchronized.
//
// This is the single point through which all log output flows.
// The lock prevents interleaved output from concurrent threads —
// without it, two threads' log lines could get mixed together at
// the byte level, making output unreadable.
//
// Flow:
//   1. Check _initialized — drop message if +init: wasn't called
//   2. Check level against _logLevel — suppress if below threshold
//   3. Build the output line in an NSMutableString:
//      a. Optional timestamp [HH:MM:SS.uuuuuu]
//      b. Level label [INFO ] or [INFO ] (with colour)
//      c. Optional source location [file:line:func]
//      d. The formatted message
//      e. Optional newline
//   4. Write the complete line to stderr in one write() call
+ (void)record:(LogLevel)level
          file:(nullable const char *)file
          line:(int)line
          func:(nullable const char *)func
       newLine:(BOOL)newLine
           fmt:(NSString *)fmt, ...
{
	// Guard: +init: must have been called before any LOG_* macro.
	// If it wasn't, print an error and drop the message.
	if (!_initialized) {
		NSString     *msg    = [NSString stringWithFormat:@"%@[LOG] error: +[Logger init:] not "
		                                                  @"called — dropping message%@",
                                                   kColorBoldRed,
                                                   kColorReset];
		NSFileHandle *handle = [NSFileHandle fileHandleWithStandardError];
		[handle writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
		if (newLine)
			[handle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
		return;
	}

	// Guard: nil format string — nothing to log
	if (fmt == nil)
		return;

	// Take a lock so only one thread writes at a time.
	// This prevents interleaved log lines from concurrent requests.
	@synchronized(self) {
		// Suppress messages below the configured level.
		// LogLevelInfo (4) means FATAL(1), ERROR(2), WARN(3), INFO(4) are
		// emitted; DEBUG(5) and TRACE(6) are suppressed.
		if (level > _logLevel) {
			return;
		}

		// Build the output line piece by piece
		NSMutableString *line_ = [NSMutableString string];

#ifdef LOG_SHOW_TIME_STAMP
		// Optional: prefix with dim timestamp [HH:MM:SS.uuuuuu]
		if (_useColor)
			[line_ appendString:kColorDim];
		[line_ appendFormat:@"[%@] ", [self logTimeStamp]];
		if (_useColor)
			[line_ appendString:kColorReset];
#endif  // LOG_SHOW_TIME_STAMP

		// Level label — coloured if TTY, plain text otherwise
		if (_useColor)
			[line_ appendString:[self levelLabelColored:level]];
		else
			[line_ appendFormat:@"%@ ", [self levelLabel:level]];

#ifdef LOG_SHOW_SOURCE_LOCATION
		// Optional: source location [file:line:func]
		if (file && func) {
			if (_useColor)
				[line_ appendFormat:@"%@[%s:%d:%s]%@ ", kColorDim, file, line, func, kColorReset];
			else
				[line_ appendFormat:@"[%s:%d:%s] ", file, line, func];
		}
#endif  // LOG_SHOW_SOURCE_LOCATION

		// Format the user's message using Objective-C variadic args
		va_list args;
		va_start(args, fmt);
		NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
		va_end(args);

		[line_ appendFormat:@"[%@]", message];

		// Optionally append a newline
		if (newLine)
			[line_ appendString:@"\n"];

		// Write the complete line to stderr in a single write call.
		// This is atomic at the OS level for reasonable line lengths,
		// preventing interleaving even under heavy concurrency.
		NSFileHandle *handle = [NSFileHandle fileHandleWithStandardError];
		[handle writeData:[line_ dataUsingEncoding:NSUTF8StringEncoding]];
	}
}

@end
