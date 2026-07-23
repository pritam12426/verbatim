/*
 * main.m — verbatimd entry point.
 *
 * This is the program's entry point and orchestrates the two-thread
 * architecture that makes verbatimd work:
 *
 *   Thread 1 (main thread):
 *     - Runs CFRunLoopRun() to keep the NSRunLoop alive.
 *     - This is REQUIRED for NSSpeechSynthesizer delegate callbacks
 *       (willSpeakWord, didFinishSpeaking) to be delivered.
 *     - Without a running run loop, speech delegate callbacks are
 *       silently dropped by the AppKit runtime.
 *
 *   Thread 2 (HTTP server thread):
 *     - Runs [HttpServer runWithConfig:], which blocks forever in the
 *       accept() loop, spawning a new NSThread per connection.
 *     - Each connection thread reads the HTTP request, calls the
 *       appropriate route handler, and writes the response.
 *
 * Why two threads?
 *   - NSSpeechSynthesizer's delegate callbacks require a running
 *     CFRunLoop on the thread that created the synthesizer.
 *     The HTTP server's blocking accept()/recv()/send() calls would
 *     prevent the run loop from ever running if they were on the
 *     same thread.
 *   - This is the same architecture as the old C/ObjC codebase, just
 *     with pthread replaced by NSThread.
 *
 * SIGPIPE handling:
 *   We ignore SIGPIPE at startup.  Without this, if a client
 *   disconnects while we're streaming a chunked response, the
 *   broken pipe signal would kill the entire server process.
 *   Instead, we handle the EPIPE error at the send() call level.
 *
 * What's different from the old main.c:
 *   - Argument parsing uses this project's own command_line.h instead
 *     of GNU argp (no more -largp linker flag).
 *   - Server thread uses NSThread instead of pthread_create/pthread_detach.
 *   - ServerConfig is an ObjC object (heap-allocated) instead of a C struct.
 *   - All output goes through NSFileHandle + LOG_* macros, not fprintf.
 */

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <signal.h>

#import "command_line.h"
#import "http_server.h"
#import "log.h"

// ── Entry point ──────────────────────────────────────────────────────────────
// The entire program lifecycle runs inside this @autoreleasepool block.
// On exit, all ObjC objects created during startup are released.
int main(int argc, char *argv[])
{
	@autoreleasepool {
		// 0. Ignore SIGPIPE so a client disconnect during streaming
		//    doesn't kill the entire server.  Without this, writing
		//    to a closed socket would trigger SIGPIPE → process death.
		//    With SIG_IGN, the write() returns EPIPE instead, which
		//    we handle gracefully at the send() call site.
		signal(SIGPIPE, SIG_IGN);

		// 1. Initialise logger with default level (INFO) so early
		//    LOG_* calls work.  We'll re-initialise with the
		//    user-specified level after argv parsing completes.
		[Logger init:LogLevelInfo];

		LOG_TRACE(@"main: starting verbatimd (argc=%d)", argc);

		// 2. Parse argv into a CommandLineArguments object.
		//    Returns nil on parse error OR if -h/--help was requested
		//    (in which case usage was already printed to stderr).
		LOG_TRACE(@"main: parsing command line arguments");
		CommandLineArguments *args = [CommandLineArguments parseArgc:argc argv:argv];

		if (!args) {
			LOG_TRACE(@"main: argument parsing failed or --help/--version");
			return EXIT_FAILURE;
		}

		// 3. Convert the parsed --log-level string ("info", "debug", etc.)
		//    into a LogLevel enum value understood by Logger.
		LogLevel level;

		if (![args resolveLogLevel:&level]) {
			LOG_TRACE(@"main: invalid log-level '%@'", args.logLevel);
			NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
			NSString     *msg          = [NSString
                stringWithFormat:@"error: invalid --log-level '%@' "
			                                  @"(expected off|fatal|error|warn|info|debug|trace)\n",
                                 args.logLevel];
			[stderrHandle writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
			return EXIT_FAILURE;
		}

		// 4. Re-initialise logger with user-specified level.
		//    This also re-detects TTY status (though it shouldn't change).
		LOG_TRACE(@"main: re-initializing logger at level=%ld", (long) level);
		[Logger init:level];

		// Log the command-line arguments at DEBUG level
		if (LOG_LEVEL_IS_ENABLED(LogLevelDebug)) {
			NSMutableString *argsStr = [NSMutableString stringWithString:@"Command-line args: ["];
			for (int i = 0; i < argc; i++) {
				[argsStr appendFormat:@"\"%s\"", argv[i]];
				if (i != argc - 1)
					[argsStr appendString:@", "];
			}
			[argsStr appendString:@"]"];
			LOG_DEBUG(@"%@", argsStr);
		}

		// Log the startup configuration at INFO level
		LOG_INFO(@"verbatim-d starting: host=%@ port=%hu rate=%.1f wpm log-level=%@",
		         args.host,
		         args.port,
		         args.rate,
		         args.logLevel);

		// 5. Build the ServerConfig the HTTP layer needs.
		//    Heap-allocated (alloc/init) so it outlives main() for as
		//    long as the server thread runs.  ARC will not release it
		//    until the thread is done and no one references it.
		LOG_TRACE(@"main: creating ServerConfig");
		ServerConfig *config = [[ServerConfig alloc] init];
		config.host          = args.host;
		config.port          = args.port;
		config.defaultRate   = args.rate;

		// 6. Validate all arguments before starting the server.
		//    This catches invalid values (bad port, out-of-range rate, etc.)
		//    early, before we've bound to a socket.
		LOG_TRACE(@"main: validating arguments");
		NSString *validationError = nil;
		if (![args validateWithError:&validationError]) {
			LOG_TRACE(@"main: validation failed — %@", validationError);
			NSFileHandle *stderrHandle = [NSFileHandle fileHandleWithStandardError];
			NSString     *msg = [NSString stringWithFormat:@"error: %@\n", validationError];
			[stderrHandle writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]];
			return EXIT_FAILURE;
		}

		// 7. Run the HTTP server on its own thread; the main thread is
		//    reserved for the run loop below.
		//
		//    NSThread is used instead of pthread_create because:
		//    - It integrates with Objective-C's memory management (ARC).
		//    - It supports blocks (initWithBlock:), which capture the
		//      config variable cleanly without void* casting.
		//    - The thread name is set for debugging in Instruments/Activity Monitor.
		LOG_TRACE(@"main: spawning server thread");
		NSThread *serverThread = [[NSThread alloc] initWithBlock:^{
			LOG_TRACE(@"main: server thread started");
			[HttpServer runWithConfig:config]; /* never returns on success */
			LOG_FATAL(@"http server thread exited unexpectedly");
			exit(1);
		}];
		serverThread.name      = @"com.pritam.verbatim.http-server";
		[serverThread start];
		LOG_TRACE(@"main: server thread started");

		// 8. Enter the CFRunLoop on the main thread.
		//
		//    This is the most important line in the program.  Without
		//    a running run loop, NSSpeechSynthesizer's delegate callbacks
		//    (willSpeakWord:ofString:, didFinishSpeaking:) are never
		//    delivered.  Those callbacks push NDJSON event lines into
		//    the VerbatimSession's queue, which the HTTP thread pulls
		//    from — this is the entire real-time streaming mechanism.
		//
		//    CFRunLoopRun() blocks forever (the HTTP server thread handles
		//    all I/O, so the main thread has nothing else to do).  The
		//    only way this process exits is via exit() or SIGTERM.
		LOG_DEBUG(
		    @"entering CFRunLoopRun() — blocking main thread for NSSpeechSynthesizer callbacks");
		CFRunLoopRun();
	}

	return EXIT_SUCCESS;
}
