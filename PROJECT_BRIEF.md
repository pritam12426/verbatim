# verbatimd — Complete Codebase Reference for a New Contributor

> **Purpose**: This document gives a new contributor a complete, accurate mental model of the codebase in one read. No speculation — only what exists in the repository as of the current commit.

---

## 1. Project Identity

| Attribute        | Value                                                                                                                            |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| **Name**         | verbatimd                                                                                                                        |
| **Language**     | Objective-C (100% .m files, compiled as `-std=c17 -fobjc-arc`)                                                                   |
| **Platform**     | macOS only (AppKit + Foundation — `NSSpeechSynthesizer` is an AppKit API)                                                         |
| **Dependencies** | Zero runtime deps. Build-time: Xcode Command Line Tools (Foundation, AppKit, pthread)                                            |
| **Binary**       | Single executable `./verbatimd` (~198 KB debug, stripped smaller)                                                                 |
| **License**      | MIT                                                                                                                              |
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
│  pthread_create(server_thread_fn) ──────────────────────────┐    │
│       ↓                                                      │    │
│  CFRunLoopRun()  [blocks forever — keeps NSSpeechSynthesizer │    │
│                   delegate callbacks alive]                    │    │
└──────────────────────────────────────────────────────────────┼────┘
                                                               │
                                                               ▼
                        ┌──────────────────────────────────────────┐
                        │   HTTP server thread (detached pthread)   │
                        │                                          │
                        │  socket → bind → listen → accept loop    │
                        │       │                                  │
                        │       ▼                                  │
                        │  pthread_create(handle_connection)       │
                        │  (one thread per connection, detached)   │
                        └──────────┬───────────────────────────────┘
                                   │
                                   ▼
                        ┌──────────────────────────────────────────┐
                        │   handle_connection (per-request thread)  │
                        │                                          │
                        │  recv_until_headers_done() → parse_head()│
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
                        │   Speech engine (global, lock-guarded)    │
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
- HTTP server runs on its own detached pthread, spawns one thread per connection.
- Speech engine is a single global `NSSpeechSynthesizer` guarded by `NSLock`. One utterance at a time.
- `sender !== synth` identity check prevents stray callbacks from a superseded synthesizer.
- Event queue uses `NSCondition` for push-from-delegate-thread / blocking-pull-from-HTTP-thread.

---

## 3. Source Tree

```
src/
├── project_config.h    # VERSION, BINARY_NAME, HOMEPAGE_URL, SHORT_DESC constants
├── command_line.h/.m   # Native ObjC argv parsing (replaces argp, no external deps)
├── log.h/.m            # Thread-safe leveled logging with ANSI colour, timestamps
├── json_writer.h/.m    # JSON serialization via NSJSONSerialization (no cJSON)
├── http_server.h/.m    # Minimal hand-rolled HTTP/1.1 server (thread-per-connection)
├── voices.h/.m         # GET /voices — shells out to `say -v '?'`, cached
├── speech_bridge.h/.m  # NSSpeechSynthesizer wrapper + NDJSON event queue
├── routes.h/.m         # The four HTTP endpoint handlers (class methods on Routes)
└── main.m              # Entry point: parses args, starts server, runs CFRunLoop
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
- `pthread_create(server_thread_fn)` → detaches, passes config via `__bridge`.
- Main thread enters `CFRunLoopRun()` — blocks forever, keeps speech callbacks alive.

### 4.2 `http_server.m` — HTTP Server

- **Socket setup**: `socket()` → `SO_REUSEADDR` → `inet_pton()` → `bind()` → `listen(16)`.
- **Accept loop**: blocking `accept()` → `malloc(connection_args)` → `pthread_create(handle_connection)` → `pthread_detach()`.
- **`handle_connection`** (per-connection pthread):
  1. `recv_until_headers_done()` — reads into growing `malloc`'d buffer until `\r\n\r\n`.
  2. `parse_head()` — returns `HttpRequest *` object (method, path, headers as `NSMutableArray<HttpHeader *>`).
  3. Body read based on `Content-Length` → `NSMutableData` → `NSString`.
  4. Route dispatch via `[Routes speakWithFD:...]` etc.
  5. `close(fd)`.

- **`http_get_header()`**: case-insensitive lookup over `req.headers` array, returns `NSString *`.
- **`http_send_response()`**: raw C function, writes `HTTP/1.1` status line + headers + body via `send()`.
- **Chunked streaming**: `http_begin_chunked_response()` → `http_write_chunk()` → `http_end_chunks()`. Used by `POST /` with `ndjson=true`.

### 4.3 `speech_bridge.m` — Speech Engine

- **Global state** (all guarded by `g_engine_lock` NSLock):
  - `g_synth` — single `NSSpeechSynthesizer` instance
  - `g_delegate` — `VerbatimSpeechDelegate` (keeps it alive)
  - `g_current_session` — the active `VerbatimSession`

- **`VerbatimSession`** (`@interface`):
  - Owns `VerbatimEventQueue` (NSMutableArray + NSCondition).
  - `-nextEvent` blocks on NSCondition until event available, returns `NSString *` or `nil`.

- **`SpeechBridge`** class methods:
  - `+speakWithSession:text:rate:voiceName:` — interrupts previous, creates new synth, starts speaking.
  - `+stop` — stops current utterance, notifies session with `finished` event.
  - `+isSpeaking` — returns whether `g_current_session != nil`.

- **`VerbatimSpeechDelegate`**:
  - `willSpeakWord:ofString:` — pushes `{"event":"word","start":N,"length":N}` to session queue.
  - `didFinishSpeaking:` — pushes `{"event":"finished","completed":bool}`, clears global state.
  - **Sender identity check**: `sender != g_synth` → ignore (stray callback from superseded synth).

- **Voice resolution**: `resolve_voice_name()` — case-insensitive match against `[NSSpeechSynthesizer availableVoices]`'s `NSVoiceName` attribute.

- **Event queue flow**:
  ```
  push_event(session, line, terminal)
    → lock → append to lines array → if terminal, set done → signal → unlock

  [session nextEvent]
    → lock → wait while empty && !done → pop front → unlock → return line
    → if done && empty → return nil
  ```

### 4.4 `routes.m` — HTTP Endpoints

All class methods on `Routes`:

- **`+speakWithFD:request:config:clientIP:`** — the main endpoint:
  1. Validates body non-empty.
  2. Reads `TTS-Voice`, `TTS-Speed`, `ndjson` headers.
  3. Maps `TTS-Speed` (1–10) → WPM (90–360) via `map_speed_to_rate()`.
  4. Counts words, estimates duration (`word_count / rate * 60`).
  5. If `ndjson=true`: begins chunked response, sends `estimate` event, calls `[SpeechBridge speakWithSession:...]`, loops `[session nextEvent]` writing chunks.
  6. If `ndjson=false`: drains events silently, returns single JSON response.

- **`+stopWithFD:request:clientIP:`** — calls `[SpeechBridge stop]`, returns `{"status":"stopped"}`.
- **`+statusWithFD:request:clientIP:`** — returns `{"speaking": bool}`.
- **`+voicesWithFD:request:clientIP:`** — calls `voicesList()`, returns JSON array.

Static helpers (file-local, not in header): `is_blank()`, `map_speed_to_rate()`, `count_words()`, `estimate_duration_seconds()`, `send_json_response()`, `send_json_error()`.

### 4.5 `voices.m` — Voice Listing

- `voicesList()` — returns cached `NSArray<VoiceInfo *>`.
- First call: `popen("/usr/bin/say -v '?' 2>/dev/null")` → read stdout → POSIX regex parse.
- Regex: `^(.+)[[:space:]]{2,}([A-Za-z_-]+)[[:space:]]+#` — matches lines like `"Albert              en_US    # Hello! ..."`.
- `rtrim()` needed because POSIX greedy `(.+)` pulls trailing whitespace into name capture.
- Cache: `g_cached` (static NSArray), never invalidated (process lifetime).

### 4.6 `json_writer.m` — JSON Serialization

- Single function: `json_serialize_alloc(object, &out_len)` → malloc'd UTF-8 buffer.
- Wraps `NSJSONSerialization` — handles string escaping correctly.
- Caller must `free()` the returned buffer.
- No JSON parsing — this project only ever *builds* JSON (POST body is raw text, not JSON).

### 4.7 `command_line.m` — Argument Parsing

- Custom implementation, no external library (replaced `argp` which is Homebrew-only on macOS).
- Supports `-H VALUE`, `--host VALUE`, `--host=VALUE` forms.
- Defaults: host `127.0.0.1`, port `5959`, rate `175`, log-level `info`.
- `-h`/`--help` and `-V`/`--version` call `exit(0)` directly — never return to caller.

### 4.8 `log.m` — Thread-Safe Logger

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
2.  malloc(connection_args) → set fd + config
3.  pthread_create(handle_connection) → detach
4.  handle_connection:
    a. recv_until_headers_done() → raw buffer
    b. parse_head() → HttpRequest* (method, path, headers)
    c. Read body: Content-Length → NSMutableData → NSString
    d. free(raw)
    e. Route dispatch: [Routes speakWithFD:fd request:req config:config clientIP:clientIP]
5.  Routes.speakWithFD:
    a. Validate body non-empty
    b. Read headers: TTS-Voice, TTS-Speed, ndjson
    c. map_speed_to_rate() → WPM
    d. count_words() + estimate_duration_seconds()
    e. If ndjson: http_begin_chunked_response() + send estimate event
    f. VerbatimSession *session = [[VerbatimSession alloc] init]
    g. [SpeechBridge speakWithSession:session text:body rate:rate voiceName:voice]
6.  SpeechBridge.speakWithSession:
    a. Lock g_engine_lock
    b. Interrupt previous session (push finished event, stopSpeaking)
    c. Create NSSpeechSynthesizer, set delegate + rate
    d. Store session as g_current_session
    e. Unlock
    f. [synth startSpeakingString:text]
7.  NSSpeechSynthesizer calls delegate on main thread's run loop:
    a. willSpeakWord → push {"event":"word","start":N,"length":N} to session queue
    b. didFinishSpeaking → push {"event":"finished","completed":bool}, clear global state
8.  HTTP thread: [session nextEvent] → blocks on NSCondition → returns event string
9.  http_write_chunk() → sends NDJSON line to client
10. Repeat 8–9 until nextEvent returns nil
11. http_end_chunks() → close(fd)
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

| Variable                    | Default | Effect                                           |
| --------------------------- | ------- | ------------------------------------------------ |
| `O_DEBUG`                   | `0`     | Enable debug build (ASan, UBSan, -g3)            |
| `O_LOG_SHOW_SOURCE_LOCATION`| `1`     | Prepend `[file:line:func]` to log output         |
| `O_LOG_SHOW_TIME_STAMP`     | `1`     | Prepend `[HH:MM:SS.ffffff]` to log output        |

### No dependency tracking

Headers not in Makefile deps. Run `make clean` after header changes.

### Formatting

```sh
clang-format -i src/*.m src/*.h    # uses .clang-format (tabs, 100-col, pointer-right)
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

| Decision                              | Why                                                                                         |
| ------------------------------------- | ------------------------------------------------------------------------------------------- |
| 100% Objective-C (no C++)             | Eliminated the only C++ in speech_bridge (std::queue → NSCondition). Zero hidden deps.      |
| No Swift runtime                      | Avoids the concurrency issue that motivated this rewrite (Swift Concurrency + speech callbacks). |
| Thread-per-connection                 | Simple, no async framework, no thread pool overhead for a low-traffic local server.         |
| CFRunLoop on main thread              | Required for NSSpeechSynthesizer delegate callbacks to fire. This is the whole point.        |
| NSLock for engine state               | Same semantics as the old std::mutex. One utterance at a time, serialised access.            |
| NSCondition for event queue           | Replaces std::condition_variable + std::queue. Push from delegate, blocking pull from HTTP.  |
| NSJSONSerialization (no cJSON)        | Project only builds JSON, never parses it. Foundation already ships the writer for free.     |
| Custom argp replacement               | argp is Homebrew-only on macOS. Own implementation is 200 lines, zero deps.                  |
| POSIX regex for voice parsing         | Already proven against `say -v '?'` output. NSTask rewrite would trade proven for unproven.  |
| Heap-allocated ServerConfig           | Outlives main() for server thread lifetime. Passed via __bridge to pthread.                  |
| No test suite                         | Audio path requires real macOS + speakers. Curl-based manual verification.                   |

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

| Task                              | Files                                                                                           |
| --------------------------------- | ----------------------------------------------------------------------------------------------- |
| Add CLI flag                      | `command_line.h` (property), `command_line.m` (parsing), `http_server.h` (ServerConfig)         |
| New HTTP endpoint                 | `routes.h` (class method decl), `routes.m` (implementation), `http_server.m` (route dispatch)   |
| Change speech event format        | `speech_bridge.m` (delegate methods, push_event calls)                                          |
| Add log level                     | `log.h` (enum + macro), `log.c` (colour handler in both default/color handlers)                 |
| Modify voice parsing              | `voices.m` (regex + parse function)                                                             |
| Change JSON output format         | `routes.m` (NSDictionary literals passed to json_serialize_alloc)                               |
| Add HTTP response header          | `http_server.m` (http_send_response or http_begin_chunked_response)                             |
| Modify event queue                | `speech_bridge.m` (VerbatimSession, VerbatimEventQueue)                                         |

---

## 11. Mental Model Checklist for Agents

- [ ] macOS only — will not compile on Linux/CI
- [ ] Main thread = CFRunLoop only — never touches I/O or networking
- [ ] HTTP server thread = accept loop, spawns per-connection pthreads
- [ ] One global NSSpeechSynthesizer, guarded by NSLock
- [ ] One utterance at a time — new requests supersede previous
- [ ] `sender !== synth` identity check is load-bearing — do not remove
- [ ] Event queue: push from delegate thread, blocking pull from HTTP thread
- [ ] NSCondition, not NSLock, for the event queue (wait/signal semantics)
- [ ] `__bridge` / `__bridge_retained` / `__bridge_transfer` for passing ObjC through C thread functions
- [ ] No JSON parsing — only JSON serialization (POST body is raw text)
- [ ] No test suite — verify with `make && ./verbatimd` + curl
- [ ] `clang-format -i src/*.m src/*.h` after any edits
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
clang-format -i src/*.m src/*.h

# Manual test
curl http://127.0.0.1:5959/status
curl http://127.0.0.1:5959/voices
curl -N -X POST http://127.0.0.1:5959/ -d "Hello world, this is verbatim."
curl -X POST http://127.0.0.1:5959/stop
```

---

_Generated from codebase inspection. Update when architecture changes._
