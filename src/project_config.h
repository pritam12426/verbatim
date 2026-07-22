/*
 * project_config.h — compile-time constants for the entire project.
 *
 * Every string, number, and URL that identifies verbatimd as a product
 * lives here.  These are static const values so the compiler can fold
 * them at compile time and each translation unit gets its own copy —
 * no linker conflicts, no need for extern declarations.
 *
 * Why constants instead of #define:
 *   - static const gives the compiler real types, enabling warnings
 *     on misuse (e.g. passing an int where a string is expected).
 *   - They appear in the debugger by name, unlike macro expansions.
 *   - They respect Objective-C namespaces and scoping rules.
 */

#import <Foundation/Foundation.h>

// ── Product identity ─────────────────────────────────────────────────────────
// Short lowercase name used in log messages, file paths, etc.
static NSString *const kVerbatim = @"verbatim";

// Executable / binary name shown in --help and --version output.
static NSString *const kMainBinary = @"verbatimd";

// ── Semantic version (semver.org) ───────────────────────────────────────────
// The full version string, used by --version and diagnostic logging.
static NSString *const kProjectVersion = @"0.1.0";

// Individual semver components, useful for compile-time comparisons or
// embedding in Info.plist without string parsing.
static const int kProjectVersionMajor = 0;  // Incompatible API changes
static const int kProjectVersionMinor = 1;  // Added functionality (backward compatible)
static const int kProjectVersionPatch = 0;  // Backward-compatible bug fixes

// ── Project metadata ────────────────────────────────────────────────────────
// Homepage URL, shown in --help output and used for issue-reporting links.
static NSString *const kProjectHomepageURL = @"https://github.com/pritam12426/verbatim";

// One-line description printed by --help.
static NSString *const kProjectShortDesc
    = @"local macOS TTS server over say command with real-time, per-word timing over HTTP";

// Author attribution, shown at the bottom of --help.
static NSString *const kAuthMessage
    = @"Author: Pritam <84720825+pritam12426@users.noreply.github.com>";
