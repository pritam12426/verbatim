/*
 * command_line.m — Native Objective-C command-line argument parsing.
 *
 * See command_line.h for the public API and usage examples.
 *
 * Implementation notes:
 *   - argv[0] is skipped (it's the program name, not an option).
 *   - Long options (--host, --port, etc.) support both "--opt=value"
 *     and "--opt value" forms, handled by +splitLongOpt:name:value:.
 *   - Short options (-H, -P, etc.) always take the next argv element
 *     as their value (no combined short options like -Hp).
 *   - Unknown options cause an error message and nil return.
 *   - NSScanner is used for numeric parsing (port, rate) instead of
 *     strtoul/strtof, giving us proper error detection and the ability
 *     to check for trailing garbage (e.g. "8080abc" is rejected).
 *   - All output goes to NSFileHandle stderr/stdout, not fprintf,
 *     to stay consistent with the rest of the ObjC codebase.
 */

#import "command_line.h"

#import <Foundation/Foundation.h>
#import <errno.h>

#import "project_config.h"

// ── Default values ───────────────────────────────────────────────────────────
// These are the built-in defaults if no CLI flags are provided.
// They match the values documented in --help output.
static NSString *const      kDefaultHost     = @"127.0.0.1";    // Loopback only (security)
static const unsigned short kDefaultPort     = 5959;            // Arbitrary high port
static const float          kDefaultRate     = 175.0f;          // Natural speech rate
static NSString *const      kDefaultLogLevel = @"info";         // Reasonable default
static NSString *const      kAppVersion      = kProjectVersion; // Must match project_config.h

@implementation CommandLineArguments

// Initialise with built-in defaults.  Called before parsing overwrites
// any values that the user explicitly provided on the command line.
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

// ── Helpers ──────────────────────────────────────────────────────────────────

// Splits "--opt=value" into ("--opt", "value").
// Returns YES if an '=' was found (and outValue is set), NO otherwise
// (outValue is set to nil, meaning the caller should look for a
// separate argv element as the value).
+ (BOOL)splitLongOpt:(NSString *)token
                name:(NSString *_Nonnull *_Nonnull)outName
               value:(NSString *_Nullable *_Nonnull)outValue
{
	NSRange eq = [token rangeOfString:@"="];

	if (eq.location == NSNotFound) {
		// No '=' found — this is just the option name, e.g. "--host"
		*outName  = token;
		*outValue = nil;
		return NO;
	}

	// Split at '=' — e.g. "--host=127.0.0.1" -> ("--host", "127.0.0.1")
	*outName  = [token substringToIndex:eq.location];
	*outValue = [token substringFromIndex:eq.location + 1];
	return YES;
}

// Prints usage information to stderr.
// Called when -h/--help is requested or when a parse error occurs.
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

// Prints "<progName> version <APP_VERSION>" to stdout.
// Called when -V/--version is requested.
+ (void)printVersion:(NSString *)progName
{
	NSString     *version      = [NSString
        stringWithFormat:@"%@ version %@\n", progName ? progName : @"program", kAppVersion];
	NSFileHandle *stdoutHandle = [NSFileHandle fileHandleWithStandardOutput];
	[stdoutHandle writeData:[version dataUsingEncoding:NSUTF8StringEncoding]];
}

// Fetches the value for an option, whether it was given as "--opt=value"
// (inlineValue != nil) or as a separate next argv element ("--opt value").
// Advances *idx past the consumed argument(s).  Returns nil (and prints
// an error) if no value is available.
//
// Parameters:
//   optDisplayName — the option name for error messages (e.g. "--host")
//   inlineValue    — value from --opt=VALUE form, or nil
//   argv/argc      — the raw argv array
//   idx            — current index; advanced past consumed elements
+ (nullable NSString *)valueForOpt:(NSString *)optDisplayName
                       inlineValue:(nullable NSString *)inlineValue
                              argv:(char *_Nonnull const *)argv
                              argc:(int)argc
                               idx:(int *)idx
{
	// If the value was inline (--host=VALUE), use it directly
	if (inlineValue != nil) {
		return inlineValue;
	}

	// Otherwise, look at the next argv element
	int next = *idx + 1;

	if (next >= argc) {
		// No next element — option is missing its value
		NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
		NSString     *msg          = [NSString
            stringWithFormat:@"error: option '%@' requires a value\n", optDisplayName];
		[stderrHandle writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
		return nil;
	}

	// Advance past the value argument
	*idx = next;
	return [NSString stringWithUTF8String:argv[next]];
}

// ── Parsing ──────────────────────────────────────────────────────────────────

// Main entry point for argument parsing.  Iterates through argv[1..argc-1],
// matching each token against known options.  Returns a fully-populated
// CommandLineArguments on success, or nil on any error.
//
// Note: -h/--help and -V/--version call exit() directly — they never
// return to the caller.  Only genuine parse errors return nil.
+ (nullable instancetype)parseArgc:(int)argc argv:(char *_Nonnull const *_Nonnull)argv
{
	LOG_TRACE(@"cmdline: parsing %d arguments", argc);

	// Create a new instance with built-in defaults
	CommandLineArguments *args = [[CommandLineArguments alloc] init];

	// Iterate through argv[1] to argv[argc-1] (skip argv[0] = program name)
	for (int i = 1; i < argc; i++) {
		NSString *token = [NSString stringWithUTF8String:argv[i]];
		LOG_TRACE(@"cmdline: argv[%d] = '%@'", i, token);

		// --help / -h: print usage and exit immediately
		if ([token isEqualToString:@"-h"] || [token isEqualToString:@"--help"]) {
			LOG_TRACE(@"cmdline: --help requested");
			[self printUsage:[NSString stringWithUTF8String:argv[0]]];
			exit(EXIT_SUCCESS);
		}

		// --version / -V: print version and exit immediately
		if ([token isEqualToString:@"-V"] || [token isEqualToString:@"--version"]) {
			LOG_TRACE(@"cmdline: --version requested");
			[self printVersion:[NSString stringWithUTF8String:argv[0]]];
			exit(EXIT_SUCCESS);
		}

		NSString *name        = token;
		NSString *inlineValue = nil;

		// For long options (--xxx), try to split on '='
		if ([token hasPrefix:@"--"]) {
			[self splitLongOpt:token name:&name value:&inlineValue];
			LOG_TRACE(@"cmdline: split long option -> name='%@', value='%@'",
			          name,
			          inlineValue ? inlineValue : @"(none)");
		}

		// Match against known options
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

			// Parse port as an integer, validate range 0-65535
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

		// Parse rate as a float
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
		// Reject NaN — NSScanner may accept "nan" as a valid float
		if (rate != rate) {
			LOG_TRACE(@"cmdline: --rate is NaN '%@'", value);
			NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
			NSString *msg = [NSString stringWithFormat:@"error: rate cannot be NaN\n"];
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

			// Store as string; validation happens in resolveLogLevel: / validateWithError:
			args.logLevel = value;
			LOG_TRACE(@"cmdline: setting logLevel='%@'", value);
		} else {
			// Unknown option — print error and usage
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

// ── LogLevel bridging ────────────────────────────────────────────────────────

// Converts the string logLevel ("info", "debug", etc.) into a LogLevel
// enum value.  Uses a static NSDictionary lookup table (initialised
// once via dispatch_once) for O(1) case-insensitive matching.
//
// Returns YES if the string was recognised, NO otherwise.
- (BOOL)resolveLogLevel:(LogLevel *)outLevel
{
	NSString *lower = [self.logLevel lowercaseString];

	// Build the lookup table once, thread-safe via dispatch_once
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
		return NO;  // Unknown log level string
	}

	if (outLevel) {
		*outLevel = (LogLevel)[value integerValue];
	}

	return YES;
}

// ── Argument validation ──────────────────────────────────────────────────────

// Validates all parsed arguments.  Called after parseArgc:argv:
// returns successfully.  Returns YES if all arguments are within
// acceptable ranges, NO with an error message otherwise.
//
// Validation rules:
//   - host: non-empty, max 253 characters (DNS name limit)
//   - port: 1024-65535 (avoid privileged ports below 1024)
//   - rate: 1.0-1000.0 WPM (reasonable range for NSSpeechSynthesizer)
//   - logLevel: must be a recognised string (off|fatal|error|warn|info|debug|trace)
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
	// Also reject NaN (rate != rate is the IEEE 754 NaN self-inequality check)
	if (self.rate != self.rate || self.rate < 1.0f || self.rate > 1000.0f) {
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
