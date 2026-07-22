# verbatimd — Complete Codebase Reference for a New Contributor

> **Purpose**: This document gives a new contributor a complete, accurate mental model of the codebase in one read. No speculation — only what exists in the repository as of the current commit.

---

## 1. Project Identity

| Attribute        | Value                                                                                                                                                |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Name**         | verbatimd                                                                                                                                            |
| **Language**     | Objective-C (100% .m files, compiled as `-std=c17 -fobjc-arc`)                                                                                       |
| **Platform**     | macOS only (AppKit + Foundation — `NSSpeechSynthesizer` is an AppKit API)                                                                            |
| **Dependencies** | Zero runtime deps. Build-time: Xcode Command Line Tools (Foundation, AppKit, pthread)                                                                |
| **Binary**       | Single executable `./verbatimd` (~243 KB debug, stripped smaller)                                                                                    |
| **License**      | MIT                                                                                                                                                  |
| **Philosophy**   | _Do one thing well._ Speak text aloud and tell a client exactly which word is being spoken, live. No Swift runtime, no Node.js, no async frameworks. |

**Not a framework.** Not a library. Not extensible at runtime. A single-purpose macOS TTS server that streams per-word timing events over HTTP.

---

## 2. High-Level Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        main thread                                │
│  CommandLineArguments.parseArgc:argv:                             │
│       ↓                                                           │
│  Logger.init: → ServerConfig.alloc/init                           │
│       ↓                                                           │
│  [NSThread startWithBlock:] ─────────────────────────────────┐    │
│       ↓                                                      │    │
│  CFRunLoopRun()  [blocks forever — keeps NSSpeechSynthesizer │    │
│                   delegate callbacks alive]                    │    │
└──────────────────────────────────────────────────────────────┼────┘
                                                               │
                                                               ▼
                        ┌──────────────────────────────────────────┐
                        │  HTTP server thread (NSThread block)      │
                        │                                          │
                        │  socket → bind → listen → accept loop    │
                        │       │                                  │
                        │       ▼                                  │
                        │  NSThread block per connection            │
                        │  (blocks, no pthread_create/detach)      │
                        └──────────┬───────────────────────────────┘
                                   │
                                   ▼
                        ┌──────────────────────────────────────────┐
                        │  Connection thread (NSThread block)       │
                        │                                          │
                        │  [HttpParse recvUntilHeadersDoneWithFD:]  │
                        │       ↓                                  │
                        │  [HttpParse parseHeadWithData:]           │
                        │       ↓                                  │
                        │  Read body (Content-Length)               │
                        │       ↓                                  │
                        │  Route dispatch:                         │
                        │    POST /    → [Routes speakWithFD:...]   │
                        │    POST /stop → [Routes stopWithFD:...]   │
                        │    GET /status → [Routes statusWithFD:...]│
                        │    GET /voices → [Routes voicesWithFD:...]│
                        │       ↓                                  │
                        │  close(fd)                                │
                        └──────────┬───────────────────────────────┘
                                   │
                                   ▼
                        ┌──────────────────────────────────────────┐
                        │  Speech engine (global, lock-guarded)     │
                        │                                          │
                        │  SpeechBridge.speakWithSession:           │
                        │    → NSSpeechSynthesizer.startSpeaking   │
                        │    → delegate willSpeakWord → push_event  │
                        │    → delegate didFinishSpeaking → push    │
                        │                                          │
                        │  VerbatimSession.nextEvent               │
                        │    → NSCondition wait/signal queue        │
                        │    → returns NDJSON string or nil         │
                        └──────────────────────────────────────────┘
```

**Key invariants:**

- Main thread runs `CFRunLoopRun()` — this is load-bearing. Without it, `NSSpeechSynthesizer` delegate callbacks (`willSpeakWord`) never fire.
- HTTP server runs on its own background thread via `[HttpServer runWithConfig:]`, spawns one NSThread block per connection.
- Speech engine is a single global `NSSpeechSynthesizer` guarded by `NSLock`. One utterance at a time.
- `sender != g_synth` identity check prevents stray callbacks from a superseded synthesizer.
- Event queue uses `NSCondition` for push-from-delegate-thread / blocking-pull-from-HTTP-thread.

---

## 3. Source Tree

```
src/
├── project_config.h         # VERSION, BINARY_NAME, HOMEPAGE_URL, SHORT_DESC constants
├── command_line.h/.m        # Native ObjC argv parsing (replaces argp, no external deps)
├── log.h/.m                 # Thread-safe leveled logging with ANSI colour, timestamps
├── json_writer.h/.m         # JSON serialization via NSJSONSerialization ([JSONWriter serialize:])
├── http_parse.h/.m          # HTTP request parsing (recv + parse head + headers)
├── http_response.h/.m       # HTTP response writing (plain + chunked streaming)
├── http_server.h/.m         # Minimal hand-rolled HTTP/1.1 server (thread-per-connection)
├── voices.h/.m              # GET /voices — shells out to `say -v '?'` via NSTask, cached
├── route_helpers.h/.m       # Shared route utilities (speed mapping, JSON response/error helpers)
├── route_speak.h/.m         # POST / handler (Routes (Speak) category, NDJSON streaming)
├── speech_bridge.h/.m       # NSSpeechSynthesizer wrapper (global engine, delegate callbacks)
├── verbatim_event_queue.h/.m # Thread-safe event queue (VerbatimSession + VerbatimEventQueue)
├── routes.h/.m              # Remaining HTTP endpoints (stop, status, voices, 404)
└── main.m                   # Entry point: parses args, starts server, runs CFRunLoop
```

**No subdirectories.** Flat `src/` with `.h/.m` pairs. Makefile uses `$(wildcard src/*.m)`.

---

## 4. Module Deep Dive

### 4.1 `main.m` — Entry & CLI

- `[CommandLineArguments parseArgc:argv:]` → fills `args` (host, port, rate, logLevel).
- Returns nil on parse error OR `-h`/`-V` (those call `exit()` directly).
- `[args resolveLogLevel:&level]` → converts string to `LogLevel` enum.
- `[Logger init:level]` → must be called before any `LOG_*` macro.
- `ServerConfig` heap-allocated (lives as long as server thread).
- `[NSThread startWithBlock:]` → launches background thread, passes config.
- Main thread enters `CFRunLoopRun()` — blocks forever, keeps speech callbacks alive.

### 4.2 `http_server.h/.m` — HTTP Server

- **Classes defined in header**:
  - `HttpHeader` — simple name/value pair (both `NSString *`)
  - `HttpRequest` — holds method, path, headers (`NSMutableArray<HttpHeader *>`), body (`NSString *`)
  - `ServerConfig` — holds host, port, defaultRate, logLevel (all properties)

- **`[HttpServer runWithConfig:]`** — class method. Socket setup (`socket()` → `SO_REUSEADDR` → `inet_pton()` → `bind()` → `listen(16)`), then blocking `accept()` loop. Each connection spawns an NSThread block.

- **Per-connection NSThread block**:
  1. `[HttpParse recvUntilHeadersDoneWithFD:...]` — reads into growing `NSMutableData` until `\r\n\r\n`.
  2. `[HttpParse parseHeadWithData:...]` — returns `HttpRequest *` object.
  3. Body read based on `Content-Length` → `NSMutableData` → `NSString`.
  4. Route dispatch via `[Routes speakWithFD:...]` etc.
  5. `close(fd)`.

- **Route dispatch** — C `if/else` chain matching method + path. No router abstraction.

### 4.3 `http_parse.h/.m` — HTTP Request Parsing

- **`[HttpParse recvUntilHeadersDoneWithFD:...]`** — reads from socket via `recv()`, appends to mutable data buffer, scans for `\r\n\r\n` delimiter. Returns the raw data containing headers (caller extracts body from remaining buffer).

- **`[HttpParse parseHeadWithData:...]`** — parses the raw header data into an `HttpRequest` object. Splits on `\r\n`, first line → method + path, remaining lines → `HttpHeader` objects (case-insensitive name, value).

- **`kHTTPMaxHeaders`, `kHTTPMaxBody`, `kHTTPMaxLine`** — static constants defining limits (defined in `.m`, not header).

### 4.4 `http_response.h/.m` — HTTP Response Writing

- **`HttpRequest (Headers)` category** — case-insensitive header lookup: `[req headerWithName:@"TTS-Voice"]`.

- **`[HttpResponse sendWithFD:statusCode:statusText:contentType:body:]`** — writes a complete HTTP response with `Content-Length`. Two `send()` calls: headers then body.

- **`[HttpResponse beginChunkedWithFD:contentType:]`** — sends chunked response headers (`Transfer-Encoding: chunked`).

- **`[HttpResponse writeChunkWithFD:data:]`** — sends a single chunk in hex-size-prefixed format (`<hex>\r\n<data>\r\n`).

- **`[HttpResponse endChunksWithFD:]`** — sends the terminating `0\r\n\r\n`.

### 4.5 `speech_bridge.h/.m` — Speech Engine

- **Global state** (all guarded by `g_engine_lock` `NSLock`):
  - `g_synth` — single `NSSpeechSynthesizer` instance
  - `g_delegate` — `VerbatimSpeechDelegate` (keeps it alive)
  - `g_current_session` — the active `VerbatimSession`

- **`+initialize`** — called once by runtime. Creates `g_engine_lock`, `g_delegate`, `g_synth`. Sets delegate on synth. This avoids the `dispatch_once` / static initializer pattern.

- **`SpeechBridge`** class methods:
  - `+speakWithSession:text:rate:voiceName:` — interrupts previous, resolves voice, creates new synth, starts speaking.
  - `+stop` — stops current utterance, notifies session with `finished` event.
  - `+isSpeaking` — returns whether `g_current_session != nil`.

- **`+resolveVoiceName:`** — case-insensitive match against `[NSSpeechSynthesizer availableVoices]`'s `NSVoiceName` attribute.

- **`VerbatimSpeechDelegate`**:
  - `willSpeakWord:ofString:` — pushes `{"event":"word","start":N,"length":N}` to session queue.
  - `didFinishSpeaking:` — pushes `{"event":"finished","completed":bool}`, clears global state.
  - **Sender identity check**: `sender != g_synth` → ignore (stray callback from superseded synth).

### 4.6 `verbatim_event_queue.h/.m` — Event Queue

- **`VerbatimSession`** — simple object that owns a `VerbatimEventQueue`.
  - `-nextEvent` blocks on NSCondition until event available, returns `NSString *` or `nil`.

- **`VerbatimEventQueue`** — the actual queue:
  - `NSMutableArray<NSString *> *lines` — pending events
  - `NSCondition *cond` — wait/signal synchronization
  - `BOOL done` — terminal flag

- **Queue flow**:
  ```
  push_event(session, line, terminal)
    → lock → append to lines array → if terminal, set done → signal → unlock

  [session nextEvent]
    → lock → wait while empty && !done → pop front → unlock → return line
    → if done && empty → return nil
  ```

### 4.7 `routes.h/.m` — HTTP Endpoints

All class methods on `Routes`:

- **`+stopWithFD:request:clientIP:`** — calls `[SpeechBridge stop]`, returns `{"status":"stopped"}`.
- **`+statusWithFD:request:clientIP:`** — returns `{"speaking": bool}`.
- **`+voicesWithFD:request:clientIP:`** — calls `[Voices voicesList]`, returns JSON array. Caches final serialized JSON bytes via `dispatch_once`.
- **`+notFoundWithFD:clientIP:`** — returns 404 JSON error.

Route dispatch is in `http_server.m` (the NSThread block), not in `routes.m`.

### 4.8 `route_helpers.h/.m` — Shared Route Utilities

- **`NSString (RouteHelpers)` category**:
  - `-isBlank` — returns YES if string is empty or whitespace-only.

- **`RouteHelpers`** class methods:
  - `+mapSpeedToRate:` — maps TTS-Speed header (1–10) to WPM (90–360), linear.
  - `+sendJSONResponseWithFD:statusCode:statusText:object:` — serializes and sends a complete JSON response. Falls back to 500 on serialization failure.
  - `+sendJSONErrorWithFD:statusCode:statusText:message:` — convenience wrapper, wraps message in `{"error":"..."}`.

### 4.9 `route_speak.h/.m` — POST / Handler

- **`Routes (Speak)` category** — separated from `routes.m` because this handler is significantly more complex.

- **`+speakWithFD:request:config:clientIP:`** — the main endpoint:
  1. Validates body non-empty.
  2. Reads `TTS-Voice`, `TTS-Speed`, `ndjson` headers.
  3. Maps `TTS-Speed` (1–10) → WPM (90–360) via `[RouteHelpers mapSpeedToRate:]`.
  4. If `ndjson=true`: begins chunked response via `[HttpResponse beginChunkedWithFD:]`.
  5. Creates `VerbatimSession`, calls `[SpeechBridge speakWithSession:...]`.
  6. Loops `[session nextEvent]` writing NDJSON chunks, or drains silently for non-ndjson.

### 4.10 `voices.h/.m` — Voice Listing

- **`[Voices voicesList]`** — returns `NSArray *` (cached via `dispatch_once` in `routes.m`).
- First call: `[[NSTask alloc] init]` with `/usr/bin/say -v '?'`, reads stdout via `NSPipe`.
- Regex: `^(.+)[[:space:]]{2,}([A-Za-z_-]+)[[:space:]]+#` — matches lines like `"Albert              en_US    # Hello! ..."`.
- Cache: final serialized JSON bytes (`NSData *`), stored in `routes.m` via `dispatch_once`.

### 4.11 `json_writer.h/.m` — JSON Serialization

- Single class method: `[JSONWriter serialize:object]` → `NSData *` (UTF-8).
- Wraps `NSJSONSerialization` — handles string escaping correctly.
- No JSON parsing — this project only ever _builds_ JSON (POST body is raw text, not JSON).

### 4.12 `command_line.h/.m` — Argument Parsing

- Custom implementation, no external library (replaced `argp` which is Homebrew-only on macOS).
- Supports `-H VALUE`, `--host VALUE`, `--host=VALUE` forms.
- Defaults: host `127.0.0.1`, port `5959`, rate `175`, log-level `info`.
- `-h`/`--help` and `-V`/`--version` call `exit(0)` directly — never return to caller.
- Argument validation: host (non-empty, max 253 chars), port (1024-65535), rate (1-1000 wpm).

### 4.13 `log.h/.m` — Thread-Safe Logger

- **Levels**: `off`(0), `fatal`(1), `error`(2), `warn`(3), `info`(4), `debug`(5), `trace`(6).
- **Thread safety**: `@synchronized(self)` on every `LOG_*` call.
- **ANSI colour**: auto-detected via `isatty(fileno(stderr))`.
- **Compile-time features** (set via Makefile `O_` variables):
  - `LOG_SHOW_SOURCE_LOCATION` — prepends `[file:line:func]`.
  - `LOG_SHOW_TIME_STAMP` — prepends `[HH:MM:SS.ffffff]`.
- **Macros**: `LOG_FATAL`, `LOG_ERROR`, `LOG_WARN`, `LOG_INFO`, `LOG_DEBUG`, `LOG_TRACE`, `LOG_PERROR` (adds `perror()`).

---

## 5. Request Lifecycle (Happy Path: POST /)

```
1.  main thread: accept() → client_fd
2.  NSThread block spawned for this connection
3.  Connection thread:
    a. [HttpParse recvUntilHeadersDoneWithFD:...] → raw data
    b. [HttpParse parseHeadWithData:] → HttpRequest* (method, path, headers)
    c. Read body: Content-Length → NSMutableData → NSString
    d. Route dispatch: [Routes speakWithFD:fd request:req config:config clientIP:clientIP]
4.  Routes.speakWithFD:
    a. Validate body non-empty
    b. Read headers: TTS-Voice, TTS-Speed, ndjson
    c. [RouteHelpers mapSpeedToRate:] → WPM
    d. If ndjson: [HttpResponse beginChunkedWithFD:contentType:@"application/x-ndjson"]
    e. VerbatimSession *session = [[VerbatimSession alloc] init]
    f. [SpeechBridge speakWithSession:session text:body rate:rate voiceName:voice]
5.  SpeechBridge.speakWithSession:
    a. Lock g_engine_lock
    b. Interrupt previous session (push finished event, stopSpeaking)
    c. Create NSSpeechSynthesizer, set delegate + rate
    d. Store session as g_current_session
    e. Unlock
    f. [synth startSpeakingString:text]
6.  NSSpeechSynthesizer calls delegate on main thread's run loop:
    a. willSpeakWord → push {"event":"word","start":N,"length":N} to session queue
    b. didFinishSpeaking → push {"event":"finished","completed":bool}, clear global state
7.  HTTP thread: [session nextEvent] → blocks on NSCondition → returns event string
8.  [HttpResponse writeChunkWithFD:fd data:lineData] → sends NDJSON line to client
9.  Repeat 7–8 until nextEvent returns nil
10. [HttpResponse endChunksWithFD:fd] → close(fd)
```

---

## 6. Build System

### `Makefile` (top-level)

```make
CC = clang
CFLAGS = -Isrc -std=c17 -fobjc-arc -Wall -Wextra -Wpedantic \
         -Wshadow -Wconversion -Wstrict-prototypes -Wmissing-prototypes
LDFLAGS += -lpthread -framework Foundation -framework AppKit

# Debug (ASan + UBSan):
make debug
# → -g3 -DDEBUG -DLOG_SHOW_SOURCE_LOCATION -DLOG_SHOW_TIME_STAMP
# → -fsanitize=address -fsanitize=undefined -ffreestanding

# Release:
make            # -O3

# Install:
make install                          # /usr/local/bin/verbatimd
make install PREFIX="$HOME/.local"    # ~/.local/bin/verbatimd
```

### Build-time options (Makefile `O_` variables)

| Variable                     | Default | Effect                                    |
| ---------------------------- | ------- | ----------------------------------------- |
| `O_DEBUG`                    | `0`     | Enable debug build (ASan, UBSan, -g3)     |
| `O_LOG_SHOW_SOURCE_LOCATION` | `1`     | Prepend `[file:line:func]` to log output  |
| `O_LOG_SHOW_TIME_STAMP`      | `1`     | Prepend `[HH:MM:SS.ffffff]` to log output |

### No dependency tracking

Headers not in Makefile deps. Run `make clean` after header changes.

### Formatting

```sh
make format                     # uses .clang-format (tabs, 100-col, pointer-right)
clang-format -i src/*.m src/*.h
```

---

## 7. Testing

**No automated test suite.** The audio path is manually verified via curl.

```sh
# Manual test sequence:
make && ./verbatimd --log-level trace

# In another terminal:
curl http://127.0.0.1:5959/status
curl http://127.0.0.1:5959/voices
curl -N -X POST http://127.0.0.1:5959/ -d "Hello world"
curl -X POST http://127.0.0.1:5959/stop
```

---

## 8. Key Design Decisions (Rationale)

| Decision                         | Why                                                                                              |
| -------------------------------- | ------------------------------------------------------------------------------------------------ |
| 100% Objective-C (no C++)        | Eliminated the only C++ in speech_bridge (std::queue → NSCondition). Zero hidden deps.           |
| No Swift runtime                 | Avoids the concurrency issue that motivated this rewrite (Swift Concurrency + speech callbacks). |
| Thread-per-connection (NSThread) | Simple, no async framework, no thread pool overhead for a low-traffic local server.              |
| CFRunLoop on main thread         | Required for NSSpeechSynthesizer delegate callbacks to fire. This is the whole point.            |
| NSLock for engine state          | Same semantics as the old std::mutex. One utterance at a time, serialised access.                |
| NSCondition for event queue      | Replaces std::condition_variable + std::queue. Push from delegate, blocking pull from HTTP.      |
| NSJSONSerialization (no cJSON)   | Project only builds JSON, never parses it. Foundation already ships the writer for free.         |
| Custom argp replacement          | argp is Homebrew-only on macOS. Own implementation is 200 lines, zero deps.                      |
| NSTask for voice listing         | Replaced popen() with NSTask+NSPipe. Foundation API, more robust process management.             |
| Heap-allocated ServerConfig      | Outlives main() for server thread lifetime.                                                      |
| No test suite                    | Audio path requires real macOS + speakers. Curl-based manual verification.                       |

---

## 9. Known Limitations (By Design)

- **macOS only** — `NSSpeechSynthesizer` is an AppKit API. Will not compile on Linux.
- **No HTTPS** — local development tool, binds to 127.0.0.1 only.
- **No test suite** — speech pipeline requires real audio output.
- **No env var support** — all config via CLI flags (explicit, reproducible).
- **No hot reload of voices** — voice list cached at first `/voices` call, never refreshed.
- **One utterance at a time** — new requests supersede current speech (by design, same as `say`).
- **`speech_bridge.m` cannot be tested in CI** — depends on AppKit, no mock path.
- **`NSSpeechSynthesizer` deprecated in macOS 14.0** — Apple recommends `AVSpeechSynthesizer`. This project deliberately uses the older API for its delegate-based word timing.
- **No WebSocket** — NDJSON streaming via HTTP chunked encoding covers the use case.

---

## 10. Files an Agent Might Need to Touch

| Task                       | Files                                                                                                     |
| -------------------------- | --------------------------------------------------------------------------------------------------------- |
| Add CLI flag               | `command_line.h` (property), `command_line.m` (parsing), `http_server.h` (ServerConfig)                   |
| New HTTP endpoint          | `routes.h` (class method decl), `routes.m` (implementation), `http_server.m` (dispatch in NSThread block) |
| Change speech event format | `speech_bridge.m` (delegate methods, push_event calls)                                                    |
| Add log level              | `log.h` (enum + macro), `log.m` (colour handler in both default/color handlers)                           |
| Modify voice parsing       | `voices.m` (NSTask + NSPipe, regex parse)                                                                 |
| Change JSON output format  | `routes.m` or `route_speak.m` (NSDictionary literals passed to `[JSONWriter serialize:]`)                 |
| Add HTTP response header   | `http_response.h/.m` (sendWithFD or beginChunkedWithFD)                                                   |
| Modify event queue         | `verbatim_event_queue.h/.m` (VerbatimSession, VerbatimEventQueue)                                         |
| Modify HTTP parsing        | `http_parse.h/.m` (recvUntilHeadersDone, parseHead)                                                       |

---

## 11. Mental Model Checklist for Agents

- [ ] macOS only — will not compile on Linux/CI
- [ ] Main thread = CFRunLoop only — never touches I/O or networking
- [ ] HTTP server thread = accept loop, spawns NSThread blocks per connection
- [ ] One global NSSpeechSynthesizer, guarded by NSLock
- [ ] One utterance at a time — new requests supersede previous
- [ ] `sender != g_synth` identity check is load-bearing — do not remove
- [ ] Event queue: push from delegate thread, blocking pull from HTTP thread
- [ ] NSCondition, not NSLock, for the event queue (wait/signal semantics)
- [ ] No JSON parsing — only JSON serialization (POST body is raw text)
- [ ] No test suite — verify with `make && ./verbatimd` + curl
- [ ] `make format` or `clang-format -i src/*.m src/*.h` after any edits
- [ ] `NSSpeechSynthesizer` deprecation warnings are expected — this is the API we wrap

---

## 12. Quick Commands

```sh
# Build release
make

# Build debug (ASan + UBSan)
make debug

# Run
./verbatimd
./verbatimd --host 0.0.0.0 --port 8080
./verbatimd --log-level trace

# Install
make install                          # /usr/local/bin
make install PREFIX="$HOME/.local"    # ~/.local/bin

# Format
make format                           # or: clang-format -i src/*.m src/*.h

# Manual test
curl http://127.0.0.1:5959/status
curl http://127.0.0.1:5959/voices
curl -N -X POST http://127.0.0.1:5959/ -d "Hello world, this is verbatim."
curl -X POST http://127.0.0.1:5959/stop
```

---

_Generated from codebase inspection. Update when architecture changes._
