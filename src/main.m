/*
 * main.m — verbatimd entry point.
 *
 * Same thread/run-loop division of labor as the old main.c: the HTTP
 * server runs on its own background thread, and the real main thread is
 * reserved to keep a run loop alive — on macOS via CFRunLoopRun(), which
 * is what lets NSSpeechSynthesizer's delegate callbacks (willSpeakWord,
 * the whole reason this project exists) actually get delivered. A plain
 * synchronous main() never has the problem that pushed this project off
 * Swift Concurrency in the first place, so that guarantee is preserved
 * here unchanged.
 *
 * What's different from main.c: argument parsing is no longer argp (an
 * external, Homebrew-only-on-macOS C library) — it's this project's own
 * command_line.h, which is why the Makefile no longer needs -largp. This
 * also replaces the placeholder main.m stub that only demonstrated
 * command_line.h/log.h wiring; this is the real thing, also starting the
 * HTTP server and entering the run loop.
 *
 * This version uses ObjC ServerConfig object (allocated on the heap)
 * instead of a C struct.
 */

#include <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <pthread.h>

#import "command_line.h"
#import "http_server.h"
#import "log.h"

static void *server_thread_fn(void *arg)
{
	ServerConfig *config = (__bridge ServerConfig *) arg;
	http_server_run(config); /* never returns on success */
	LOG_FATAL(@"http server thread exited unexpectedly");
	exit(1);
}

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

		LOG_INFO(@"verbatim-d starting: host=%@ port=%hu rate=%.1f wpm log-level=%@",
		         args.host,
		         args.port,
		         args.rate,
		         args.logLevel);

		// 4. Build the ServerConfig the HTTP layer needs.  Heap-allocated
		//    so it outlives main() for as long as the server thread runs.
		ServerConfig *config = [[ServerConfig alloc] init];
		config.host          = args.host;
		config.port          = args.port;
		config.defaultRate   = args.rate;

		// 5. Validate all arguments before starting the server.
		NSString *validationError = nil;
		if (![args validateWithError:&validationError]) {
			fprintf(stderr, "error: %s\n", [validationError UTF8String]);
			return EXIT_FAILURE;
		}

		// 6. Run the HTTP server on its own thread; the main thread is
		//    reserved for the run loop below.
		pthread_t server_thread;
		if (pthread_create(&server_thread, NULL, server_thread_fn, (__bridge void *) config) != 0) {
			LOG_FATAL(@"could not start HTTP server thread");
			return EXIT_FAILURE;
		}
		pthread_detach(server_thread);

		LOG_DEBUG(
		    @"entering CFRunLoopRun() — blocking main thread for NSSpeechSynthesizer callbacks");
		CFRunLoopRun();
	}

	return EXIT_SUCCESS;
}
