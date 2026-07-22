/*
 * command_line.h — Native Objective-C command-line argument parsing
 *
 * A small, dependency-free replacement for GNU argp. Parses argv directly
 * using Foundation, with no C arg-parsing library involved.
 *
 * Supported forms per option:
 *   -H VALUE
 *   --host VALUE
 *   --host=VALUE
 *
 * Usage:
 *   CommandLineArguments *args = [CommandLineArguments parseArgc:argc argv:argv];
 *   if (!args) {
 *       // parseArgc:argv: already printed an error/usage message
 *       exit(EXIT_FAILURE);
 *   }
 *   NSLog(@"host=%@ port=%hu rate=%.1f logLevel=%@",
 *         args.host, args.port, args.rate, args.logLevel);
 */

#import <Foundation/Foundation.h>

#import "log.h"

NS_ASSUME_NONNULL_BEGIN

@interface CommandLineArguments : NSObject

@property(nonatomic, copy) NSString *host;      // default: 127.0.0.1
@property(nonatomic) unsigned short  port;      // default: 5959
@property(nonatomic) float           rate;      // default: 175
@property(nonatomic, copy) NSString *logLevel;  // default: "info"

// Parses argv (as passed to main). Returns nil (with an error + usage
// message printed to stderr) if parsing fails. -h/--help and -V/--version
// print their message and call exit() directly with status 0, so they
// never return to the caller — only genuine parse errors return nil.
+ (nullable instancetype)parseArgc:(int)argc argv:(char *_Nonnull const *_Nonnull)argv;

// Converts the parsed logLevel string ("off|fatal|error|warn|info|debug|trace")
// into a LogLevel value from log.h. Returns NO if the string is not recognised.
- (BOOL)resolveLogLevel:(LogLevel *)outLevel;

// Validates all parsed arguments. Returns YES if valid, NO if invalid
// (error message stored in *error if non-NULL).
- (BOOL)validateWithError:(NSString *_Nullable *_Nullable)error;

// Prints usage information to stderr.
+ (void)printUsage:(NSString *)progName;

// Prints "<progName> version <APP_VERSION>" to stdout.
+ (void)printVersion:(NSString *)progName;

@end

NS_ASSUME_NONNULL_END
