/*
 * log.h — Thread-safe logging implementation for Objective-C
 *
 * Features:
 *   - Six log levels: FATAL, ERROR, WARN, INFO, DEBUG, TRACE
 *   - Compile-time timestamps (-DLOG_SHOW_TIME_STAMP)
 *   - Compile-time source location (-DLOG_SHOW_SOURCE_LOCATION)
 *   - ANSI colour output (auto-disabled for non-TTY)
 *   - Thread safety via @synchronized
 *
 * Usage:
 *   [Logger init:LOG_LEVEL_DEBUG];
 *   LOG_INFO(@"server started on port %d", 8080);
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Log severity levels (lower number = higher priority)
typedef NS_ENUM(NSInteger, LogLevel) {
	LogLevelOff   = 0,
	LogLevelFatal = 1,
	LogLevelError = 2,
	LogLevelWarn  = 3,
	LogLevelInfo  = 4,
	LogLevelDebug = 5,
	LogLevelTrace = 6,
};

@interface Logger : NSObject

// Initialize the logger. Thread-safe.
+ (void)init:(LogLevel)level;

// Logger configuration
+ (void)setLevel:(LogLevel)level;
+ (LogLevel)getLevel;

// Returns YES if the logger is currently emitting ANSI color codes.
// Color is enabled automatically when the output is a TTY.
+ (BOOL)useColor;

// Internal implementation — do not call directly.
+ (void)record:(LogLevel)level
          file:(nullable const char *)file
          line:(int)line
          func:(nullable const char *)func
       newLine:(BOOL)newLine
           fmt:(NSString *)fmt, ... NS_FORMAT_FUNCTION(6, 7);

// Logs strerror(errno) as a separate LOG_ERROR line.  Used by LOG_PERROR.
+ (void)logErrno;

@end

// --------------------------------------------------
// Public logging macros
// --------------------------------------------------

// Check if messages at the given level would be emitted right now.
#define LOG_LEVEL_IS_ENABLED(level) ([Logger getLevel] >= (level))

#ifdef LOG_SHOW_SOURCE_LOCATION

// Log with custom newline behaviour (NO = no newline, YES = with newline)
// Used internally; prefer LOG_FATAL / LOG_ERROR / LOG_WARN / etc.
#define LOG_CUSTOM(LOG_LEVEL, NEW_LINE, ...) \
	[Logger record:LOG_LEVEL                 \
	          file:__FILE__                  \
	          line:__LINE__                  \
	          func:__func__                  \
	       newLine:NEW_LINE                  \
	           fmt:__VA_ARGS__]

// Log an error and append strerror(errno)
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

#else

// Log with custom newline behaviour (NO = no newline, YES = with newline)
// Used internally; prefer LOG_FATAL / LOG_ERROR / LOG_WARN / etc.
#define LOG_CUSTOM(LOG_LEVEL, NEW_LINE, ...)                                              \
	[Logger record:LOG_LEVEL file:NULL line:0 func:NULL newLine:NEW_LINE fmt:__VA_ARGS__]

// Log an error and append strerror(errno)
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
