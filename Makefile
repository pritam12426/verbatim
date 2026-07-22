UNAME_S := $(shell uname -s)

PREFIX ?= /usr/local
MANPREFIX ?= $(PREFIX)/share/man

STRIP ?= strip
PKG_CONFIG ?= pkg-config
INSTALL ?= install

BUILD = build
BIN   = verbatimd

HEADERS   = $(wildcard src/*.h)
SRC       = $(wildcard src/*.m)

MFLAGS += -Isrc -std=c17

MFLAGS +=  -Wshadow -Wconversion \
           -Wall -Wextra -Wpedantic \
           -Wno-missing-field-initializers \
           -Wstrict-prototypes -Wmissing-prototypes

# Common flags
MFLAGS += -Isrc -fobjc-arc
LDLIBS += -lpthread -framework Foundation -framework AppKit

# Build options (set via command line, e.g. `make O_DEBUG=1`)
O_DEBUG := 0                     ## Enable debug build (ASan, UBSan, -g3)
O_LOG_SHOW_SOURCE_LOCATION := 1  ## Prepend [file:line:func] to log output
O_LOG_SHOW_TIME_STAMP := 1       ## Prepend [HH:MM:SS.ffffff] to log output

# Auto-enable flags for debug builds
ifneq ($(filter debug,$(MAKECMDGOALS)),)
	O_DEBUG := 1
	O_LOG_SHOW_SOURCE_LOCATION := 1
	O_LOG_SHOW_TIME_STAMP := 1
endif

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

# Convert O_ variables to -D flags
ifeq ($(strip $(O_LOG_SHOW_SOURCE_LOCATION)),1)
	MFLAGS += -DLOG_SHOW_SOURCE_LOCATION
endif

ifeq ($(strip $(O_LOG_SHOW_TIME_STAMP)),1)
	MFLAGS += -DLOG_SHOW_TIME_STAMP
endif

OUT += $(SRC:%.m=$(BUILD)/%.o)

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

$(BUILD)/%.o: %.m
	@mkdir -p $(dir $@)
	$(CC) $(MFLAGS) -c $< -o $@

$(BIN): $(SRC) $(OUT)  ## Build the linkrot binary
	$(CC) $(LDFLAGS) -o $@ $(OUT) $(LDLIBS)

debug: $(BIN)  ## Build the debug binary run `make debug -B O_DEBUG=1`

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

.PHONY: all install uninstall strip clean debug format
