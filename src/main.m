/*
 * main.m — Example entry point wiring together command_line.h and log.h
 */

#import <Foundation/Foundation.h>

#import "command_line.h"
#import "log.h"

int main(int argc, char *argv[])
{
	@autoreleasepool {
		// 1. Parse argv into a CommandLineArguments object.
		//    Returns nil on parse error OR -h/--help (usage is already
		//    printed to stderr in both cases).
		CommandLineArguments *args = [CommandLineArguments parseArgc:argc argv:argv];

		if (!args) {
			return EXIT_FAILURE;
		}

		// 2. Convert the parsed --log-level string into a LogLevel enum
		//    value understood by Logger.
		LogLevel level;

		if (![args resolveLogLevel:&level]) {
			fprintf(stderr,
			        "error: invalid --log-level '%s' "
			        "(expected off|fatal|error|warn|info|debug|trace)\n",
			        [args.logLevel UTF8String]);
			return EXIT_FAILURE;
		}

		// 3. Initialise the logger before any LOG_* macro is used.
		[Logger init:level];

		// 4. Use the parsed values.
		LOG_INFO(@"starting up: host=%@ port=%hu rate=%.1f wpm log-level=%@",
		         args.host,
		         args.port,
		         args.rate,
		         args.logLevel);

		// ... rest of your program (bind to args.host/args.port, etc.) ...

		LOG_DEBUG(@"this only prints if --log-level debug or trace was passed");
	}

	return EXIT_SUCCESS;
}
