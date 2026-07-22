/*
 * log.h — Thread-safe logging system for Objective-C.
 *
 * This is the project's sole logging interface.  Every LOG_* call
 * routes through +[Logger record:file:line:func:newLine:fmt:], which
 * is serialised via @synchronized so lines from concurrent threads
 * never interleave.
 *
 * Features:
 *   - Six severity levels: FATAL, ERROR, WARN, INFO, DEBUG, TRACE
 *   - Compile-time source location (-DLOG_SHOW_SOURCE_LOCATION)
 *   - Compile-time microsecond timestamps (-DLOG_SHOW_TIME_STAMP)
 *   - ANSI colour output (auto-disabled when stderr is not a TTY)
 *   - Thread safety via @synchronized(self) on the Logger class
 *
 * Build-time flags (pass to clang via -D):
 *   LOG_SHOW_SOURCE_LOCATION  — include __FILE__:__LINE__:__func__ in output
 *   LOG_SHOW_TIME_STAMP       — prefix each line with HH:MM:SS.uuuuuu
 *
 * Usage (from any .m file):
 *   [Logger init:LogLevelDebug];              // call once at startup
 *   LOG_INFO(@"server started on port %d", 8080);
 *   LOG_TRACE(@"checking connection fd=%d", fd);
 *   LOG_ERROR(@"malloc failed: %s", strerror(errno));
 *
 * Colour scheme (when isatty(stderr)):
 *   FATAL  — bold blue      (stands out as a crash-level event)
 *   ERROR  — bold red       (failures requiring attention)
 *   WARN   — bold yellow    (suspicious but non-fatal)
 *   INFO   — bold green     (normal lifecycle events)
 *   DEBUG  — bold cyan      (developer-facing diagnostics)
 *   TRACE  — bold magenta   (extremely verbose, per-call tracing)
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// ── Log severity levels ──────────────────────────────────────────────────────
// Lower number = higher priority.  A message is emitted only if its
// level is <= the current threshold (set via +[Logger init:]).
// For example, at LogLevelInfo, only FATAL/ERROR/WARN/INFO are emitted;
// DEBUG and TRACE are suppressed.
typedef NS_ENUM(NSInteger, LogLevel) {
	LogLevelOff   = 0,  // Disable all logging (can't be set via --log-level)
	LogLevelFatal = 1,  // Unrecoverable errors — process is about to die
	LogLevelError = 2,  // Recoverable failures (bad input, I/O errors)
	LogLevelWarn  = 3,  // Suspicious conditions that aren't errors
	LogLevelInfo  = 4,  // Normal lifecycle events (server started, request served)
	LogLevelDebug = 5,  // Developer diagnostics (variable values, branch taken)
	LogLevelTrace = 6,  // Extremely verbose per-call tracing (function entry/exit)
};

// ── Logger class ─────────────────────────────────────────────────────────────
// All class methods — no instances are created.  The class object itself
// acts as the singleton, and @synchronized(self) on the class provides
// mutual exclusion for the mutable state (_logLevel, _useColor).
@interface Logger : NSObject

// Initialise the logger with the given minimum level.
// Must be called at least once before any LOG_* macro, or messages
// are dropped with an error to stderr.  Safe to call multiple times
// (e.g. to re-initialise at a user-specified level after argv parsing).
+ (void)init:(LogLevel)level;

// Change the minimum log level at runtime.  Thread-safe.
+ (void)setLevel:(LogLevel)level;

// Return the current minimum log level.  Thread-safe.
+ (LogLevel)getLevel;

// Returns YES if the logger is currently emitting ANSI colour codes.
// Colour is enabled automatically when stderr is a TTY (detected
// via isatty(fileno(stderr)) during +init:).
+ (BOOL)useColor;

// Core logging entry point — called by the LOG_* macros.
// Do not call directly; use the macros instead, which fill in
// __FILE__, __LINE__, and __func__ automatically.
//
// Parameters:
//   level   — severity; message is suppressed if level > current threshold
//   file    — source file path (__FILE__), or NULL if LOG_SHOW_SOURCE_LOCATION
//   line    — source line number (__LINE__), or 0 if LOG_SHOW_SOURCE_LOCATION
//   func    — function name (__func__), or NULL if LOG_SHOW_SOURCE_LOCATION
//   newLine — YES to append '\n' after the formatted message
//   fmt     — NSString format string (supports NS_FORMAT_FUNCTION checking)
+ (void)record:(LogLevel)level
          file:(nullable const char *)file
          line:(int)line
          func:(nullable const char *)func
       newLine:(BOOL)newLine
           fmt:(NSString *)fmt, ... NS_FORMAT_FUNCTION(6, 7);

// Logs strerror(errno) as a separate LOG_ERROR line.
// Intended to be called immediately after a system call failure,
// while errno is still valid.  Used by the LOG_PERROR macro.
+ (void)logErrno;

@end

// ── Public logging macros ────────────────────────────────────────────────────
// These are the primary API.  They expand to a single message-send
// to +[Logger record:...], filling in file/line/func automatically.
//
// LOG_FATAL(...)   — equivalent to LOG_ERROR but at fatal priority
// LOG_ERROR(...)   — recoverable failure
// LOG_WARN(...)    — suspicious but non-fatal
// LOG_INFO(...)    — normal lifecycle event
// LOG_DEBUG(...)   — developer diagnostic
// LOG_TRACE(...)   — extremely verbose per-call tracing
// LOG_PERROR(...)  — LOG_ERROR + strerror(errno) on a separate line
// LOG_CUSTOM(...)  — internal: custom level and newline control
//
// Compile-time check for whether a given level is currently enabled,
// useful for guarding expensive argument construction:
//   if (LOG_LEVEL_IS_ENABLED(LogLevelTrace)) {
//       NSString *expensive = [obj expensiveDescription];
//       LOG_TRACE(@"obj = %@", expensive);
//   }
#define LOG_LEVEL_IS_ENABLED(level) ([Logger getLevel] >= (level))

// ── Variant with source location ─────────────────────────────────────────────
// When LOG_SHOW_SOURCE_LOCATION is defined at build time, every log
// line includes [file:line:func] for easy identification of where
// the message originated.  The macros pass __FILE__, __LINE__, and
// __func__ to +[Logger record:...].
#ifdef LOG_SHOW_SOURCE_LOCATION

// LOG_CUSTOM — internal macro for custom level and newline control.
// Used by LOG_PERROR to suppress the newline between the user's
// message and the strerror(errno) line.
#define LOG_CUSTOM(LOG_LEVEL, NEW_LINE, ...) \
	[Logger record:LOG_LEVEL                 \
	          file:__FILE__                  \
	          line:__LINE__                  \
	          func:__func__                  \
	       newLine:NEW_LINE                  \
	           fmt:__VA_ARGS__]

// LOG_PERROR — logs a user message at ERROR level, then appends
// strerror(errno) via +[Logger logErrno].  The user message is
// written with newLine:NO so the errno line appears on the same
// conceptual line (but as a separate record).
#define LOG_PERROR(...)              \
	do {                             \
		[Logger record:LogLevelError \
		          file:__FILE__      \
		          line:__LINE__      \
		          func:__func__      \
		       newLine:NO            \
		           fmt:__VA_ARGS__]; \
		[Logger logErrno];           \
	} while (0)

#define LOG_FATAL(...)           \
	[Logger record:LogLevelFatal \
	          file:__FILE__      \
	          line:__LINE__      \
	          func:__func__      \
	       newLine:YES           \
	           fmt:__VA_ARGS__]

#define LOG_ERROR(...)           \
	[Logger record:LogLevelError \
	          file:__FILE__      \
	          line:__LINE__      \
	          func:__func__      \
	       newLine:YES           \
	           fmt:__VA_ARGS__]

#define LOG_WARN(...)           \
	[Logger record:LogLevelWarn \
	          file:__FILE__     \
	          line:__LINE__     \
	          func:__func__     \
	       newLine:YES          \
	           fmt:__VA_ARGS__]

#define LOG_INFO(...)           \
	[Logger record:LogLevelInfo \
	          file:__FILE__     \
	          line:__LINE__     \
	          func:__func__     \
	       newLine:YES          \
	           fmt:__VA_ARGS__]

#define LOG_DEBUG(...)           \
	[Logger record:LogLevelDebug \
	          file:__FILE__      \
	          line:__LINE__      \
	          func:__func__      \
	       newLine:YES           \
	           fmt:__VA_ARGS__]

#define LOG_TRACE(...)           \
	[Logger record:LogLevelTrace \
	          file:__FILE__      \
	          line:__LINE__      \
	          func:__func__      \
	       newLine:YES           \
	           fmt:__VA_ARGS__]

// ── Variant without source location ──────────────────────────────────────────
// When LOG_SHOW_SOURCE_LOCATION is NOT defined, the macros pass
// NULL/0/NULL for file/line/func, producing cleaner output at the
// cost of not knowing where each message originated.
#else

#define LOG_CUSTOM(LOG_LEVEL, NEW_LINE, ...)                                              \
	[Logger record:LOG_LEVEL file:NULL line:0 func:NULL newLine:NEW_LINE fmt:__VA_ARGS__]

#define LOG_PERROR(...)                                                                      \
	do {                                                                                     \
		[Logger record:LogLevelError file:NULL line:0 func:NULL newLine:NO fmt:__VA_ARGS__]; \
		[Logger logErrno];                                                                   \
	} while (0)

#define LOG_FATAL(...)                                                                   \
	[Logger record:LogLevelFatal file:NULL line:0 func:NULL newLine:YES fmt:__VA_ARGS__]

#define LOG_ERROR(...)                                                                   \
	[Logger record:LogLevelError file:NULL line:0 func:NULL newLine:YES fmt:__VA_ARGS__]

#define LOG_WARN(...)                                                                   \
	[Logger record:LogLevelWarn file:NULL line:0 func:NULL newLine:YES fmt:__VA_ARGS__]

#define LOG_INFO(...)                                                                   \
	[Logger record:LogLevelInfo file:NULL line:0 func:NULL newLine:YES fmt:__VA_ARGS__]

#define LOG_DEBUG(...)                                                                   \
	[Logger record:LogLevelDebug file:NULL line:0 func:NULL newLine:YES fmt:__VA_ARGS__]

#define LOG_TRACE(...)                                                                   \
	[Logger record:LogLevelTrace file:NULL line:0 func:NULL newLine:YES fmt:__VA_ARGS__]

#endif  // LOG_SHOW_SOURCE_LOCATION

NS_ASSUME_NONNULL_END
