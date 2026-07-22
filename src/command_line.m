/*
 * command_line.m — Native Objective-C command-line argument parsing
 *
 * See command_line.h for usage.
 */

#import "command_line.h"

#import "project_config.h"

// Default values
#define DEFAULT_HOST      @"127.0.0.1"
#define DEFAULT_PORT      5959
#define DEFAULT_RATE      175.0f
#define DEFAULT_LOG_LEVEL @"info"

@implementation CommandLineArguments

- (instancetype)init
{
	self = [super init];

	if (self) {
		_host     = DEFAULT_HOST;
		_port     = DEFAULT_PORT;
		_rate     = DEFAULT_RATE;
		_logLevel = DEFAULT_LOG_LEVEL;
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

+ (void)printUsage:(const char *)progName
{
	fprintf(stderr,
	        "Usage: " MAIN_BINARY " [OPTIONS]\n" MAIN_BINARY " - " PROJECT_SHORT_DESC "\n"
	        "\n"
	        "Options:\n"
	        "  -H, --host=HOST         Host to bind to (default: 127.0.0.1)\n"
	        "  -P, --port=PORT         Port to listen on (default: 5959)\n"
	        "  -R, --rate=RATE         Default speaking rate, in words per minute (default: 175)\n"
	        "  -L, --log-level=LEVEL   Log level: [off|trace|debug|info|warn|error|fatal] (default: info)\n"
	        "  -h, --help              Print this help message\n"
	        "  -V, --version           Print version information\n"
	        "\n"
	        "Report bugs to: " PROJECT_HOMEPAGE_URL "/issues\n" AUTH_MESSAGE "\n");
}

+ (void)printVersion:(const char *)progName
{
	// Version info is normal program output, not an error — goes to stdout,
	// unlike usage/error messages which go to stderr.
	printf("%s version %s\n", progName ? progName : "program", APP_VERSION);
}

// Fetches the value for an option, whether it was given as "--opt=value"
// or as a separate "next" argv element ("--opt value" / "-o value").
// Advances *idx past the consumed argument(s). Returns nil (and logs an
// error) if no value is available.
+ (nullable NSString *)valueForOpt:(NSString *)optDisplayName
                       inlineValue:(nullable NSString *)inlineValue
                              argv:(char *const *)argv
                              argc:(int)argc
                               idx:(int *)idx
{
	if (inlineValue != nil) {
		return inlineValue;
	}

	int next = *idx + 1;

	if (next >= argc) {
		fprintf(stderr, "error: option '%s' requires a value\n", [optDisplayName UTF8String]);
		return nil;
	}

	*idx = next;
	return [NSString stringWithUTF8String:argv[next]];
}

// ── Parsing ─────────────────────────────────────────────────────────────────

+ (nullable instancetype)parseArgc:(int)argc argv:(char *const _Nonnull *)argv
{
	CommandLineArguments *args = [[CommandLineArguments alloc] init];

	for (int i = 1; i < argc; i++) {
		NSString *token = [NSString stringWithUTF8String:argv[i]];

		if ([token isEqualToString:@"-h"] || [token isEqualToString:@"--help"]) {
			[self printUsage:argv[0]];
			exit(EXIT_SUCCESS);
		}

		if ([token isEqualToString:@"-V"] || [token isEqualToString:@"--version"]) {
			[self printVersion:argv[0]];
			exit(EXIT_SUCCESS);
		}

		NSString *name        = token;
		NSString *inlineValue = nil;

		if ([token hasPrefix:@"--"]) {
			[self splitLongOpt:token name:&name value:&inlineValue];
		}

		if ([name isEqualToString:@"-H"] || [name isEqualToString:@"--host"]) {
			NSString *value = [self valueForOpt:name
			                        inlineValue:inlineValue
			                               argv:argv
			                               argc:argc
			                                idx:&i];

			if (!value) {
				[self printUsage:argv[0]];
				return nil;
			}

			args.host = value;
		} else if ([name isEqualToString:@"-P"] || [name isEqualToString:@"--port"]) {
			NSString *value = [self valueForOpt:name
			                        inlineValue:inlineValue
			                               argv:argv
			                               argc:argc
			                                idx:&i];

			if (!value) {
				[self printUsage:argv[0]];
				return nil;
			}

			args.port = (unsigned short) strtoul([value UTF8String], NULL, 10);
		} else if ([name isEqualToString:@"-R"] || [name isEqualToString:@"--rate"]) {
			NSString *value = [self valueForOpt:name
			                        inlineValue:inlineValue
			                               argv:argv
			                               argc:argc
			                                idx:&i];

			if (!value) {
				[self printUsage:argv[0]];
				return nil;
			}

			args.rate = strtof([value UTF8String], NULL);
		} else if ([name isEqualToString:@"-L"] || [name isEqualToString:@"--log-level"]) {
			NSString *value = [self valueForOpt:name
			                        inlineValue:inlineValue
			                               argv:argv
			                               argc:argc
			                                idx:&i];

			if (!value) {
				[self printUsage:argv[0]];
				return nil;
			}

			args.logLevel = value;
		} else {
			fprintf(stderr, "error: unrecognized option '%s'\n", [token UTF8String]);
			[self printUsage:argv[0]];
			return nil;
		}
	}

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
	// Validate host
	if (self.host.length == 0) {
		if (error)
			*error = @"host cannot be empty";
		return NO;
	}

	if (self.host.length > 253) {
		if (error)
			*error = @"host exceeds maximum length (253 characters)";
		return NO;
	}

	// Validate port (1-65535)
	if (self.port == 0) {
		if (error)
			*error = @"port must be between 1 and 65535";
		return NO;
	}

	// Validate rate (1-1000 wpm, reasonable range for NSSpeechSynthesizer)
	if (self.rate < 1.0f || self.rate > 1000.0f) {
		if (error)
			*error = @"rate must be between 1 and 1000 words per minute";
		return NO;
	}

	// Validate log level is recognised
	LogLevel level;
	if (![self resolveLogLevel:&level]) {
		if (error)
			*error = [NSString stringWithFormat:@"invalid log-level '%@'", self.logLevel];
		return NO;
	}

	return YES;
}

@end
