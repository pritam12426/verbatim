/*
 * log.m — Thread-safe logging implementation for Objective-C
 *
 * Features:
 *   - Six log levels: FATAL, ERROR, WARN, INFO, DEBUG, TRACE
 *   - Compile-time timestamps (-DLOG_SHOW_TIME_STAMP)
 *   - Compile-time source location (-DLOG_SHOW_SOURCE_LOCATION)
 *   - ANSI colour output (auto-disabled for non-TTY)
 *   - Thread safety via @synchronized
 */

#import "log.h"

#import <Foundation/Foundation.h>

// ANSI colour codes
static NSString *const kColorReset       = @"\x1b[0m";
static NSString *const kColorBoldRed     = @"\x1b[1;31m";
static NSString *const kColorBoldGreen   = @"\x1b[1;32m";
static NSString *const kColorBoldYellow  = @"\x1b[1;33m";
static NSString *const kColorBoldBlue    = @"\x1b[1;34m";
static NSString *const kColorBoldMagenta = @"\x1b[1;35m";
static NSString *const kColorBoldCyan    = @"\x1b[1;36m";
static NSString *const kColorDim         = @"\x1b[2m";

// ── Logger state ─────────────────────────────────────────────────────────────
//
// Protected by @synchronized(self).
// Since log_record() always takes a write-lock (to prevent interleaved output),
// a simple @synchronized block is cleaner than manual mutex operations.

static LogLevel _logLevel    = LogLevelInfo;
static BOOL     _useColor    = NO;
static BOOL     _initialized = NO;

@implementation Logger

// ── Internal helpers (called with lock already held) ─────────────────────

+ (NSString *)levelLabel:(LogLevel)level
{
	switch (level) {
	case LogLevelFatal:
		return @"FATAL";
	case LogLevelError:
		return @"ERROR";
	case LogLevelWarn:
		return @"WARN ";
	case LogLevelInfo:
		return @"INFO ";
	case LogLevelDebug:
		return @"DEBUG";
	case LogLevelTrace:
		return @"TRACE";
	default:
		return @"UNKWN";
	}
}

+ (NSString *)levelLabelColored:(LogLevel)level
{
	switch (level) {
	case LogLevelFatal:
		return [NSString stringWithFormat:@"%@FATAL%@", kColorBoldBlue, kColorReset];
	case LogLevelError:
		return [NSString stringWithFormat:@"%@ERROR%@", kColorBoldRed, kColorReset];
	case LogLevelWarn:
		return [NSString stringWithFormat:@"%@WARN %@", kColorBoldYellow, kColorReset];
	case LogLevelInfo:
		return [NSString stringWithFormat:@"%@INFO %@", kColorBoldGreen, kColorReset];
	case LogLevelDebug:
		return [NSString stringWithFormat:@"%@DEBUG%@", kColorBoldCyan, kColorReset];
	case LogLevelTrace:
		return [NSString stringWithFormat:@"%@TRACE%@", kColorBoldMagenta, kColorReset];
	default:
		return [NSString stringWithFormat:@"%@UNKWN%@", kColorBoldBlue, kColorReset];
	}
}

#ifdef LOG_SHOW_TIME_STAMP

// Returns a microsecond-precision timestamp string: "HH:MM:SS.uuuuuu"
+ (NSString *)logTimeStamp
{
	NSTimeInterval interval = [[NSDate date] timeIntervalSince1970];
	long long      seconds  = (long long) interval;
	int            us       = (int) ((interval - (double) seconds) * 1000000.0);

	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateFormat       = @"HH:mm:ss";
	formatter.timeZone         = [NSTimeZone localTimeZone];

	NSDate   *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval) seconds];
	NSString *time = [formatter stringFromDate:date];

	return [NSString stringWithFormat:@"%@.%06d", time, us];
}

#endif  // LOG_SHOW_TIME_STAMP

// ── Public API ────────────────────────────────────────────────────────────────

// Initialise the logger. Thread-safe; may be called multiple times.
+ (void)init:(LogLevel)level
{
	@synchronized(self) {
		_initialized = YES;
		_useColor    = isatty(fileno(stderr)) ? YES : NO;
		_logLevel    = level;
	}
}

// Set the minimum log level; messages below this are suppressed
+ (void)setLevel:(LogLevel)level
{
	@synchronized(self) {
		_logLevel = level;
	}
}

// Get the current minimum log level
+ (LogLevel)getLevel
{
	@synchronized(self) {
		return _logLevel;
	}
}

// Check whether ANSI colour is enabled
+ (BOOL)useColor
{
	@synchronized(self) {
		return _useColor;
	}
}

// Logs strerror(errno) as a separate LOG_ERROR line.  Used by LOG_PERROR.
+ (void)logErrno
{
	int         savedErrno = errno;
	const char *msg        = strerror(savedErrno);
	NSString   *message    = [NSString stringWithFormat:@"[LOG] errno=%d: %s", savedErrno, msg];

	NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
	[stderrHandle writeData:[message dataUsingEncoding:NSUTF8StringEncoding]];
	[stderrHandle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}

// Core logging function: formats and writes a log message.
// Called by the LOG_* macros. Thread-safe via @synchronized.
+ (void)record:(LogLevel)level
          file:(nullable const char *)file
          line:(int)line
          func:(nullable const char *)func
       newLine:(BOOL)newLine
           fmt:(NSString *)fmt, ...
{
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

	if (fmt == nil)
		return;

	// Take a lock so only one thread writes at a time
	// (prevents interleaved log lines from concurrent requests)
	@synchronized(self) {
		// Suppress messages below the configured level
		if (level > _logLevel) {
			return;
		}

		NSMutableString *line_ = [NSMutableString string];

#ifdef LOG_SHOW_TIME_STAMP
		if (_useColor)
			[line_ appendString:kColorDim];
		[line_ appendFormat:@"[%@] ", [self logTimeStamp]];
		if (_useColor)
			[line_ appendString:kColorReset];
#endif  // LOG_SHOW_TIME_STAMP

		if (_useColor)
			[line_ appendString:[self levelLabelColored:level]];
		else
			[line_ appendFormat:@"[%@] ", [self levelLabel:level]];

#ifdef LOG_SHOW_SOURCE_LOCATION
		if (file && func) {
			if (_useColor)
				[line_ appendFormat:@"%@[%s:%d:%s]%@ ", kColorDim, file, line, func, kColorReset];
			else
				[line_ appendFormat:@"[%s:%d:%s] ", file, line, func];
		}
#endif  // LOG_SHOW_SOURCE_LOCATION

		va_list args;
		va_start(args, fmt);
		NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
		va_end(args);

		[line_ appendString:message];

		if (newLine)
			[line_ appendString:@"\n"];

		NSFileHandle *handle = [NSFileHandle fileHandleWithStandardError];
		[handle writeData:[line_ dataUsingEncoding:NSUTF8StringEncoding]];
	}
}

@end
