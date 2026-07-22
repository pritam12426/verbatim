/*
 * command_line.m — Native Objective-C command-line argument parsing
 *
 * See command_line.h for usage.
 */

#import "command_line.h"

#import <Foundation/Foundation.h>
#import <errno.h>

#import "project_config.h"

// Default values
static NSString *const      kDefaultHost     = @"127.0.0.1";
static const unsigned short kDefaultPort     = 5959;
static const float          kDefaultRate     = 175.0f;
static NSString *const      kDefaultLogLevel = @"info";
static NSString *const      kAppVersion      = @"0.1.0";

@implementation CommandLineArguments

- (instancetype)init
{
	self = [super init];

	if (self) {
		_host     = kDefaultHost;
		_port     = kDefaultPort;
		_rate     = kDefaultRate;
		_logLevel = kDefaultLogLevel;
	}

	return self;
}

// ── Helpers ────────────────────────────────────────────────────────────────

// Splits "--opt=value" into ("--opt", "value"). Returns NO if there's no '='.
+ (BOOL)splitLongOpt:(NSString *)token
                name:(NSString *_Nonnull *_Nonnull)outName
               value:(NSString *_Nullable *_Nonnull)outValue
{
	NSRange eq = [token rangeOfString:@"="];

	if (eq.location == NSNotFound) {
		*outName  = token;
		*outValue = nil;
		return NO;
	}

	*outName  = [token substringToIndex:eq.location];
	*outValue = [token substringFromIndex:eq.location + 1];
	return YES;
}

+ (void)printUsage:(NSString *)progName
{
	NSString *usage = [NSString
	    stringWithFormat:
	        @"Usage: %@ [OPTIONS]\n"
	        @"%@ — %@\n"
	        @"\n"
	        @"Options:\n"
	        @"  -H, --host=HOST         Host to bind to (default: 127.0.0.1)\n"
	        @"  -P, --port=PORT         Port to listen on (default: 5959)\n"
	        @"  -R, --rate=RATE         Default speaking rate, in words per minute (default: 175)\n"
	        @"  -L, --log-level=LEVEL   Log level: [off|trace|debug|info|warn|error|fatal] "
	        @"(default: info)\n"
	        @"  -h, --help              Print this help message\n"
	        @"  -V, --version           Print version information\n"
	        @"\n"
	        @"Report bugs to: %@/issues\n%@",
	        kMainBinary,
	        kMainBinary,
	        kProjectShortDesc,
	        kProjectHomepageURL,
	        kAuthMessage];

	NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
	[stderrHandle
	    writeData:[[usage stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
}

+ (void)printVersion:(NSString *)progName
{
	NSString     *version      = [NSString
        stringWithFormat:@"%@ version %@\n", progName ? progName : @"program", kAppVersion];
	NSFileHandle *stdoutHandle = [NSFileHandle fileHandleWithStandardOutput];
	[stdoutHandle writeData:[version dataUsingEncoding:NSUTF8StringEncoding]];
}

// Fetches the value for an option, whether it was given as "--opt=value"
// or as a separate "next" argv element ("--opt value" / "-o value").
// Advances *idx past the consumed argument(s). Returns nil (and logs an
// error) if no value is available.
+ (nullable NSString *)valueForOpt:(NSString *)optDisplayName
                       inlineValue:(nullable NSString *)inlineValue
                              argv:(char *_Nonnull const *)argv
                              argc:(int)argc
                               idx:(int *)idx
{
	if (inlineValue != nil) {
		return inlineValue;
	}

	int next = *idx + 1;

	if (next >= argc) {
		NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
		NSString     *msg          = [NSString
            stringWithFormat:@"error: option '%@' requires a value\n", optDisplayName];
		[stderrHandle writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
		return nil;
	}

	*idx = next;
	return [NSString stringWithUTF8String:argv[next]];
}

// ── Parsing ─────────────────────────────────────────────────────────────────

+ (nullable instancetype)parseArgc:(int)argc argv:(char *_Nonnull const *_Nonnull)argv
{
	LOG_TRACE(@"cmdline: parsing %d arguments", argc);

	CommandLineArguments *args = [[CommandLineArguments alloc] init];

	for (int i = 1; i < argc; i++) {
		NSString *token = [NSString stringWithUTF8String:argv[i]];
		LOG_TRACE(@"cmdline: argv[%d] = '%@'", i, token);

		if ([token isEqualToString:@"-h"] || [token isEqualToString:@"--help"]) {
			LOG_TRACE(@"cmdline: --help requested");
			[self printUsage:[NSString stringWithUTF8String:argv[0]]];
			exit(EXIT_SUCCESS);
		}

		if ([token isEqualToString:@"-V"] || [token isEqualToString:@"--version"]) {
			LOG_TRACE(@"cmdline: --version requested");
			[self printVersion:[NSString stringWithUTF8String:argv[0]]];
			exit(EXIT_SUCCESS);
		}

		NSString *name        = token;
		NSString *inlineValue = nil;

		if ([token hasPrefix:@"--"]) {
			[self splitLongOpt:token name:&name value:&inlineValue];
			LOG_TRACE(@"cmdline: split long option -> name='%@', value='%@'",
			          name,
			          inlineValue ? inlineValue : @"(none)");
		}

		if ([name isEqualToString:@"-H"] || [name isEqualToString:@"--host"]) {
			NSString *value = [self valueForOpt:name
			                        inlineValue:inlineValue
			                               argv:argv
			                               argc:argc
			                                idx:&i];

			if (!value) {
				LOG_TRACE(@"cmdline: --host missing value");
				[self printUsage:[NSString stringWithUTF8String:argv[0]]];
				return nil;
			}

			LOG_TRACE(@"cmdline: setting host='%@'", value);
			args.host = value;
		} else if ([name isEqualToString:@"-P"] || [name isEqualToString:@"--port"]) {
			NSString *value = [self valueForOpt:name
			                        inlineValue:inlineValue
			                               argv:argv
			                               argc:argc
			                                idx:&i];

			if (!value) {
				LOG_TRACE(@"cmdline: --port missing value");
				[self printUsage:[NSString stringWithUTF8String:argv[0]]];
				return nil;
			}

			NSScanner *scanner = [NSScanner scannerWithString:value];
			long long  port    = 0;
			if (![scanner scanLongLong:&port] || ![scanner isAtEnd] || port < 0 || port > 65535) {
				LOG_TRACE(@"cmdline: --port invalid value '%@'", value);
				NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
				NSString *msg = [NSString stringWithFormat:@"error: invalid port '%@'\n", value];
				[stderrHandle writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
				[self printUsage:[NSString stringWithUTF8String:argv[0]]];
				return nil;
			}
			args.port = (unsigned short) port;
			LOG_TRACE(@"cmdline: setting port=%hu", args.port);
		} else if ([name isEqualToString:@"-R"] || [name isEqualToString:@"--rate"]) {
			NSString *value = [self valueForOpt:name
			                        inlineValue:inlineValue
			                               argv:argv
			                               argc:argc
			                                idx:&i];

			if (!value) {
				LOG_TRACE(@"cmdline: --rate missing value");
				[self printUsage:[NSString stringWithUTF8String:argv[0]]];
				return nil;
			}

			NSScanner *scanner = [NSScanner scannerWithString:value];
			float      rate    = 0.0f;
			if (![scanner scanFloat:&rate] || ![scanner isAtEnd]) {
				LOG_TRACE(@"cmdline: --rate invalid value '%@'", value);
				NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
				NSString *msg = [NSString stringWithFormat:@"error: invalid rate '%@'\n", value];
				[stderrHandle writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
				[self printUsage:[NSString stringWithUTF8String:argv[0]]];
				return nil;
			}
			args.rate = rate;
			LOG_TRACE(@"cmdline: setting rate=%.1f", (double) args.rate);
		} else if ([name isEqualToString:@"-L"] || [name isEqualToString:@"--log-level"]) {
			NSString *value = [self valueForOpt:name
			                        inlineValue:inlineValue
			                               argv:argv
			                               argc:argc
			                                idx:&i];

			if (!value) {
				LOG_TRACE(@"cmdline: --log-level missing value");
				[self printUsage:[NSString stringWithUTF8String:argv[0]]];
				return nil;
			}

			args.logLevel = value;
			LOG_TRACE(@"cmdline: setting logLevel='%@'", value);
		} else {
			LOG_TRACE(@"cmdline: unrecognized option '%@'", token);
			NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
			NSString *msg = [NSString stringWithFormat:@"error: unrecognized option '%@'\n", token];
			[stderrHandle writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
			[self printUsage:[NSString stringWithUTF8String:argv[0]]];
			return nil;
		}
	}

	LOG_TRACE(@"cmdline: parsing complete — host=%@ port=%hu rate=%.1f logLevel=%@",
	          args.host,
	          args.port,
	          (double) args.rate,
	          args.logLevel);
	return args;
}

// ── LogLevel bridging ────────────────────────────────────────────────────

- (BOOL)resolveLogLevel:(LogLevel *)outLevel
{
	NSString *lower = [self.logLevel lowercaseString];

	static NSDictionary<NSString *, NSNumber *> *map = nil;
	static dispatch_once_t                       onceToken;
	dispatch_once(&onceToken, ^{
		map = @{
			@"off": @(LogLevelOff),
			@"fatal": @(LogLevelFatal),
			@"error": @(LogLevelError),
			@"warn": @(LogLevelWarn),
			@"info": @(LogLevelInfo),
			@"debug": @(LogLevelDebug),
			@"trace": @(LogLevelTrace),
		};
	});

	NSNumber *value = map[lower];

	if (!value) {
		return NO;
	}

	if (outLevel) {
		*outLevel = (LogLevel)[value integerValue];
	}

	return YES;
}

// ── Argument validation ──────────────────────────────────────────────────

- (BOOL)validateWithError:(NSString **)error
{
	LOG_TRACE(@"cmdline: validating arguments");

	// Validate host
	if (self.host.length == 0) {
		LOG_TRACE(@"cmdline: validation failed — host is empty");
		if (error)
			*error = @"host cannot be empty";
		return NO;
	}

	if (self.host.length > 253) {
		LOG_TRACE(@"cmdline: validation failed — host too long (%lu chars)",
		          (unsigned long) self.host.length);
		if (error)
			*error = @"host exceeds maximum length (253 characters)";
		return NO;
	}

	// Validate port (1024-65535)
	if (self.port < 1024) {
		LOG_TRACE(@"cmdline: validation failed — port %hu out of range", self.port);
		if (error)
			*error = @"port must be between 1024 and 65535";
		return NO;
	}

	// Validate rate (1-1000 wpm, reasonable range for NSSpeechSynthesizer)
	if (self.rate < 1.0f || self.rate > 1000.0f) {
		LOG_TRACE(@"cmdline: validation failed — rate %.1f out of range", (double) self.rate);
		if (error)
			*error = @"rate must be between 1 and 1000 words per minute";
		return NO;
	}

	// Validate log level is recognised
	LogLevel level;
	if (![self resolveLogLevel:&level]) {
		LOG_TRACE(@"cmdline: validation failed — invalid log-level '%@'", self.logLevel);
		if (error)
			*error = [NSString stringWithFormat:@"invalid log-level '%@'", self.logLevel];
		return NO;
	}

	LOG_TRACE(@"cmdline: validation passed");
	return YES;
}

@end
