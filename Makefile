# ============================================================================
# Makefile for verbatimd — a local macOS TTS server
# ============================================================================
#
# Build system for the verbatimd Objective-C codebase.
#
# Quick start:
#   make              — release build (O3, no sanitizers)
#   make debug        — debug build (ASan, UBSan, -g3)
#   make format       — auto-format all source files
#   make install      — install to /usr/local/bin
#   make clean        — remove build artifacts
#   make help         — show all available targets and options
#
# Build options (set via command line):
#   make O_DEBUG=0                       — disable debug even for `make debug`
#   make O_LOG_SHOW_SOURCE_LOCATION=0    — disable [file:line:func] in logs
#   make O_LOG_SHOW_TIME_STAMP=0         — disable timestamps in logs
#
# Architecture:
#   - Source files: src/*.m (Objective-C)
#   - Headers:      src/*.h
#   - Build dir:    build/src/ (mirrors source layout)
#   - Output:       verbatimd (in project root)
#
# Dependencies:
#   - macOS SDK (Foundation, AppKit frameworks)
#   - Xcode Command Line Tools (clang, make)
#   - No external libraries (no Homebrew, no pkg-config)
#
# ============================================================================

# ── Platform detection ────────────────────────────────────────────────────────
# Detect the OS (currently macOS-only, but future-proofing for Linux/GNUstep)
UNAME_S := $(shell uname -s)

# ── Install paths ─────────────────────────────────────────────────────────────
# Standard GNU install directories, overridable via command line
PREFIX ?= /usr/local
MANPREFIX ?= $(PREFIX)/share/man

# ── External tools ────────────────────────────────────────────────────────────
# All overridable so the user can point to custom versions
STRIP ?= strip
PKG_CONFIG ?= pkg-config
INSTALL ?= install

# ── Build output ──────────────────────────────────────────────────────────────
BUILD = build
BIN   = verbatimd

# ── Source discovery ──────────────────────────────────────────────────────────
# Auto-discover all .h and .m files in src/.  No need to list them manually.
HEADERS   = $(wildcard src/*.h)
SRC       = $(wildcard src/*.m)

# ── Compiler flags ────────────────────────────────────────────────────────────

# Include path and C standard
MFLAGS += -Isrc -std=c17

# Strict warnings — catch bugs at compile time
MFLAGS += -Wshadow -Wconversion \
          -Wall -Wextra -Wpedantic \
          -Wno-missing-field-initializers \
          -Wstrict-prototypes -Wmissing-prototypes

# Common flags for all builds
#   -Isrc:          add src/ to the header search path
#   -fobjc-arc:     enable Automatic Reference Counting (no manual retain/release)
MFLAGS += -Isrc -fobjc-arc

# Linker flags — macOS frameworks and pthread
LDLIBS += -lpthread -framework Foundation -framework AppKit

# ── Build options ─────────────────────────────────────────────────────────────
# These can be set via command line: `make O_DEBUG=1`
# Or overridden per-target (debug target auto-enables them)

# Build options (set via command line, e.g. `make O_DEBUG=1`)
O_DEBUG := 0                     ## Enable debug build (ASan, UBSan, -g3)
O_LOG_SHOW_SOURCE_LOCATION := 1  ## Prepend [file:line:func] to log output
O_LOG_SHOW_TIME_STAMP := 1       ## Prepend [HH:MM:SS.ffffff] to log output

# ── Debug build auto-enable ───────────────────────────────────────────────────
# When the user runs `make debug`, automatically enable debug options
# so they don't have to remember the flags.
ifneq ($(filter debug,$(MAKECMDGOALS)),)
	O_DEBUG := 1
	O_LOG_SHOW_SOURCE_LOCATION := 1
	O_LOG_SHOW_TIME_STAMP := 1
endif

# ── Debug vs Release configuration ────────────────────────────────────────────
# Debug build:
#   - -g3: maximum debug info (for lldb/Instruments)
#   - -DDEBUG: enables assert() and debug-only code paths
#   - -DLOG_SHOW_SOURCE_LOCATION: adds [file:line:func] to log output
#   - -fsanitize=address: Address Sanitizer (catches buffer overflows, use-after-free)
#   - -fsanitize=undefined: Undefined Behavior Sanitizer (catches signed overflow, etc.)
#   - -fstack-usage: print stack usage per function (helps find stack hogs)
#   - -ffreestanding: for clang only (avoids some ASan false positives)
#
# Release build:
#   - -O3: maximum optimization (inlining, vectorization, etc.)
#   - No sanitizers (they add ~2x overhead)
ifeq ($(strip $(O_DEBUG)),1)
	MFLAGS += -g3 -DDEBUG -DLOG_SHOW_SOURCE_LOCATION

	LDFLAGS += -fsanitize=address -fsanitize=undefined
	MFLAGS += -fstack-usage \
	          -fsanitize=address \
	          -fsanitize=undefined

    ifneq (,$(findstring clang,$(CC)))
		MFLAGS += -ffreestanding
    endif
else
	MFLAGS += -O3
endif

# ── Convert O_ variables to -D flags ──────────────────────────────────────────
# These preprocessor flags control log output format:
#   LOG_SHOW_SOURCE_LOCATION — adds [file:line:func] to each log line
#   LOG_SHOW_TIME_STAMP      — adds [HH:MM:SS.uuuuuu] to each log line
ifeq ($(strip $(O_LOG_SHOW_SOURCE_LOCATION)),1)
	MFLAGS += -DLOG_SHOW_SOURCE_LOCATION
endif

ifeq ($(strip $(O_LOG_SHOW_TIME_STAMP)),1)
	MFLAGS += -DLOG_SHOW_TIME_STAMP
endif

# ── Object file list ──────────────────────────────────────────────────────────
# Convert each src/*.m to build/src/*.o, preserving directory structure
OUT += $(SRC:%.m=$(BUILD)/%.o)

# ── Targets ───────────────────────────────────────────────────────────────────

# Default target: build the release binary
all: $(BIN)

help:  ## Show this help
	@echo "Variable:"
	@awk 'BEGIN {FS="  ## "} \
		/^O_[a-zA-Z_]+[[:space:]]*:=/ { \
		split($$1, a, /[[:space:]]*:=/); \
		printf "  \033[36m%-30s\033[0m %s\n", a[1], $$2; \
	}' $(MAKEFILE_LIST)

	@echo
	@echo "Targets:"
	@grep -hE '^[a-zA-Z_-]+:.*  ## ' $(MAKEFILE_LIST) | \
	awk 'BEGIN {FS="  ## "}; {printf "  \033[33m%-15s\033[0m %s\n", $$1, $$2}'

$(BUILD):  ## Create build directories automatically
	mkdir -p $(BUILD)

# Compile each .m file to a .o file in the build directory
# mkdir -p ensures the directory structure mirrors src/
$(BUILD)/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(MFLAGS) -c $< -o $@

# Link all object files into the final binary
$(BIN): $(SRC) $(OUT)  ## Build the verbatimd binary
	$(CC) $(LDFLAGS) -o $@ $(OUT) $(LDLIBS)

debug: $(BIN)  ## Build the debug binary (ASan + UBSan enabled)

install: all  ## Install the verbatimd binary
	$(INSTALL) -m 0755 -d $(DESTDIR)$(PREFIX)/bin
	$(INSTALL) -m 0755 $(BIN) $(DESTDIR)$(PREFIX)/bin

clean:  ## Clean up verbatimd artifacts
	$(RM) -f $(OUT) $(BIN)

format:  ## Format (src/*.h src/*.m) files of the code base
	/Library/Developer/CommandLineTools/usr/bin/clang-format -i src/*.h src/*.m

uninstall:  ## Uninstall the verbatimd binary
	$(RM) $(DESTDIR)$(PREFIX)/bin/$(BIN)

strip: $(BIN)  ## Strip the verbatimd binary
	$(STRIP) $^

PLIST_IN  = verbatimd.plist.in
PLIST_OUT = $(HOME)/Library/LaunchAgents/local.verbatimd.plist

install-launch-agent: all  ## Install verbatimd as a launchd agent
	@mkdir -p $(HOME)/Library/LaunchAgents
	@mkdir -p $(HOME)/Library/Logs/verbatimd
	sed 's|~|$(HOME)|g' $(PLIST_IN) > $(PLIST_OUT)
	launchctl unload $(PLIST_OUT) 2>/dev/null || true
	launchctl load $(PLIST_OUT)
	@echo "installed and loaded $(PLIST_OUT)"

uninstall-launch-agent:  ## Remove verbatimd launchd agent
	launchctl unload $(PLIST_OUT) 2>/dev/null || true
	$(RM) $(PLIST_OUT)
	@echo "removed $(PLIST_OUT)"

# Declare phony targets (targets that don't produce a file with that name)
.PHONY: all install uninstall strip clean debug format install-launch-agent uninstall-launch-agent
