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

// ANSI colour codes
#define COLOR_RESET        "\x1b[0m"
#define COLOR_BOLD_RED     "\x1b[1;31m"
#define COLOR_BOLD_GREEN   "\x1b[1;32m"
#define COLOR_BOLD_YELLOW  "\x1b[1;33m"
#define COLOR_BOLD_BLUE    "\x1b[1;34m"
#define COLOR_BOLD_MAGENTA "\x1b[1;35m"
#define COLOR_BOLD_CYAN    "\x1b[1;36m"
#define COLOR_DIM          "\x1b[2m"

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

// Print the log-level label without colour
+ (void)defaultLogHandler:(LogLevel)level
{
	switch (level) {
		case LogLevelFatal: fprintf(stderr, "[FATAL] "); break;
		case LogLevelError: fprintf(stderr, "[ERROR] "); break;
		case LogLevelWarn:  fprintf(stderr, "[WARN ] ");  break;
		case LogLevelInfo:  fprintf(stderr, "[INFO ] ");  break;
		case LogLevelDebug: fprintf(stderr, "[DEBUG] "); break;
		case LogLevelTrace: fprintf(stderr, "[TRACE] "); break;
		default:            fprintf(stderr, "[UNKWN] "); break;
	}
}

// Print the log-level label with ANSI colour
+ (void)colorLogHandler:(LogLevel)level
{
	switch (level) {
		case LogLevelFatal:
			fprintf(stderr, "💀 [" COLOR_BOLD_BLUE "FATAL" COLOR_RESET "] ");
			break;
		case LogLevelError:
			fprintf(stderr, "🚨 [" COLOR_BOLD_RED "ERROR" COLOR_RESET "] ");
			break;
		case LogLevelWarn:
			fprintf(stderr, "⚠️  [" COLOR_BOLD_YELLOW "WARN " COLOR_RESET "] ");
			break;
		case LogLevelInfo:
			fprintf(stderr, "ℹ️  [" COLOR_BOLD_GREEN "INFO " COLOR_RESET "] ");
			break;
		case LogLevelDebug:
			fprintf(stderr, "🛠️  [" COLOR_BOLD_CYAN "DEBUG" COLOR_RESET "] ");
			break;
		case LogLevelTrace:
			fprintf(stderr, "🔬 [" COLOR_BOLD_MAGENTA "TRACE" COLOR_RESET "] ");
			break;
		default:
			fprintf(stderr, "[" COLOR_BOLD_BLUE "UNKWN" COLOR_RESET "] ");
			break;
	}
}

#ifdef LOG_SHOW_TIME_STAMP

// Print a microsecond-precision timestamp at the start of each log line
+ (void)logTimeStampHandler:(BOOL)useColor
{
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);

	struct tm tmNow;
	localtime_r(&ts.tv_sec, &tmNow);

	char timestamp[20];
	strftime(timestamp, sizeof(timestamp), "%H:%M:%S", &tmNow);

	int us = (int) (ts.tv_nsec / 1000);  // convert ns → microseconds

	if (useColor)
		fprintf(stderr, COLOR_DIM);
	fprintf(stderr, "[%s.%06d] ", timestamp, us);
	if (useColor)
		fprintf(stderr, COLOR_RESET);
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
		fprintf(stderr,
		        COLOR_BOLD_RED
		        "[LOG] error: +[Logger init:] not called — dropping message" COLOR_RESET);
		if (newLine)
			fputc('\n', stderr);
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

#ifdef LOG_SHOW_TIME_STAMP
		[self logTimeStampHandler:_useColor];
#endif  // LOG_SHOW_TIME_STAMP

		if (_useColor)
			[self colorLogHandler:level];
		else
			[self defaultLogHandler:level];

#ifdef LOG_SHOW_SOURCE_LOCATION
		if (file && func) {
			fprintf(stderr,
			        "%s[%s:%d:%s]%s ",
			        _useColor ? COLOR_DIM : "",
			        file,
			        line,
			        func,
			        _useColor ? COLOR_RESET : "");
		}
#endif  // LOG_SHOW_SOURCE_LOCATION

		va_list args;
		va_start(args, fmt);
		NSString *message = [[NSString alloc] initWithFormat:fmt arguments:args];
		va_end(args);

		fprintf(stderr, "%s", [message UTF8String]);

		if (newLine)
			fputc('\n', stderr);

		fflush(stderr);
	}
}

@end
