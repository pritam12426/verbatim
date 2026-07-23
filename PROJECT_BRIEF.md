# PROJECT_BRIEF.md — Complete Codebase Reference

> For user-facing docs, see [README.md](README.md). For developer guide, see [DEV.md](DEV.md).

---

## Project Overview

verbatimd is a local macOS TTS server. It speaks text aloud via `NSSpeechSynthesizer` and streams real-time per-word timing events as NDJSON over HTTP, enabling per-word highlighting as words are spoken.

- **Language:** 100% Objective-C (`.m` files, compiled as `-std=c17 -fobjc-arc`)
- **Platform:** macOS only (`NSSpeechSynthesizer` is an AppKit API)
- **Dependencies:** Zero runtime deps. Build-time: Xcode Command Line Tools (Foundation, AppKit, pthread)
- **Binary:** Single executable `./verbatimd` (~126 KB arm64)
- **Version:** 1.0.0
- **License:** MIT

## Complete Architecture

```mermaid
graph TD
    subgraph "Main thread"
        A[main.m] -->|parse argv| B[CommandLineArguments]
        A -->|start server thread| C[NSThread: HttpServer.runWithConfig:]
        A -->|CFRunLoopRun forever| D[AppKit run loop]
    end

    subgraph "HTTP server thread"
        C -->|socket/bind/listen| E[accept loop]
        E -->|throttle at 64| F{thread limit}
        F -->|NSThread per connection| G[handleConnectionWithFD:config:]
    end

    subgraph "Connection thread"
        G -->|SO_RCVTIMEO 30s| H[recv]
        H -->|HttpParse| I[HttpRequest]
        I -->|validate Content-Length| J{route dispatch}
        J -->|POST /| K[route_speak]
        J -->|POST /stop| L[Routes.stop]
        J -->|GET /status| M[Routes.status]
        J -->|GET /voices| N[Routes.voices]
        J -->|unknown| O[Routes.notFound]
    end

    subgraph "Speech engine"
        K -->|create session| P[VerbatimSession]
        K -->|speak| Q[SpeechBridge]
        Q -->|create synthesizer| R[NSSpeechSynthesizer]
        R -->|willSpeakWord| S[VerbatimSpeechDelegate]
        R -->|didFinishSpeaking| S
        S -->|push events (inside lock)| P
        K -->|pull events| P
        P -->|sendAll chunks| T[HttpResponse]
    end
```

### Key invariants

- Main thread runs `CFRunLoopRun()` — this is load-bearing. Without it, `NSSpeechSynthesizer` delegate callbacks never fire.
- HTTP server runs on its own background thread, spawns one NSThread block per connection.
- Speech engine is a single global `NSSpeechSynthesizer` guarded by `NSLock`. One utterance at a time.
- `sender != g_synth` identity check prevents stray callbacks from a superseded synthesizer.
- **All event pushes happen inside `g_engine_lock`** to prevent ordering inversions with concurrent `stop()`.
- Event queue uses `NSCondition` for push-from-delegate / blocking-pull-from-HTTP.
- Lock ordering is always: `g_engine_lock` → queue `NSCondition`. Consistent everywhere, no deadlock.

## Execution Flow

### Startup (`main.m`)

1. `signal(SIGPIPE, SIG_IGN)` — prevent client disconnect from killing the server
2. `[Logger init:LogLevelInfo]` — initialize logger at default level
3. `[CommandLineArguments parseArgc:argv:]` — parse CLI args (returns nil on error or `-h`/`-V`)
4. `[args resolveLogLevel:&level]` — convert string to `LogLevel` enum
5. `[Logger init:level]` — reinitialize at user-specified level
6. Build `ServerConfig` (heap-allocated, outlives main())
7. `[args validateWithError:]` — validate host (non-empty, ≤253 chars), port (1024–65535), rate (1–1000 WPM, not NaN)
8. `[NSThread startWithBlock:]` — launch HTTP server thread
9. `CFRunLoopRun()` — block main thread forever (required for speech callbacks)

### Request lifecycle (POST /)

1. `accept()` → client_fd
2. `setsockopt(SO_RCVTIMEO, 30s)` on client socket (slowloris mitigation)
3. NSThread block spawned for this connection (throttled at 64 concurrent)
4. Connection thread: `[HttpParse recvUntilHeadersDoneWithFD:...]` → raw data
5. `[HttpParse parseHeadWithData:]` → `HttpRequest*` (method, path, headers) — uses NSString character offsets (safe for non-ASCII)
6. Validate `Content-Length` with `NSScanner` (reject non-numeric/negative)
7. Read body, reject truncated (short recv) and oversized (>1 MB)
8. Route dispatch: `[Routes speakWithFD:fd request:req config:config clientIP:clientIP]`
9. Validate body non-empty, read `TTS-Voice`/`TTS-Speed`/`ndjson` headers
10. `[RouteHelpers mapSpeedToRate:]` → WPM
11. If ndjson: `[HttpResponse beginChunkedWithFD:...]` — returns BOOL, abort on failure
12. `VerbatimSession *session = [[VerbatimSession alloc] init]`
13. `[SpeechBridge speakWithSession:session text:body rate:rate voiceName:voice]`
14. Loop `[session nextEvent]` → write NDJSON chunks via `sendAll` → end chunks when nil returned
15. Check overall stream deadline (3× estimated speech time + 30s, minimum 60s)

### Speech engine flow

1. `[SpeechBridge speakWithSession:text:rate:voiceName:]` acquires `g_engine_lock`
2. Saves references to previous session/synth
3. Resolves voice name via `resolveVoiceName:` (case-insensitive match against `NSVoiceName` attribute)
4. Creates new `NSSpeechSynthesizer`, assigns delegate + rate
5. Updates global state (`g_synth`, `g_delegate`, `g_current_session`)
6. **Pushes `{"event":"started"}` while holding lock** — prevents concurrent stop() from injecting terminal first
7. Releases lock
8. Interrupts previous synth (if any) — sends `finished` event with `completed:false`
9. Calls `[synth startSpeakingString:text]`
10. Delegate callbacks fire on main thread's run loop:
    - `willSpeakWord:ofString:` — acquires lock, pushes `{"event":"word","start":N,"length":N}` **inside lock**, releases
    - `didFinishSpeaking:` — acquires lock, pushes `{"event":"finished","completed":bool}` **inside lock**, clears global state, releases

## Source Tree Walkthrough

### `project_config.h`

Compile-time constants: `kVerbatim` (product name), `kMainBinary` (binary name), `kProjectVersion` ("1.0.0"), `kProjectHomepageURL`, `kProjectShortDesc`, `kAuthMessage`. All `static const` — no linker conflicts.

### `command_line.h/.m`

Custom argument parser replacing GNU argp (which requires Homebrew on macOS). Supports `-H VALUE`, `--host VALUE`, `--host=VALUE` forms. Returns `CommandLineArguments` object with `host`, `port`, `rate`, `logLevel` properties. Validation: host non-empty ≤253 chars, port 1024–65535, rate 1–1000 WPM **and not NaN** (`rate != rate` IEEE 754 check), log level must be recognized. `-h`/`-V` call `exit()` directly.

### `log.h/.m`

Thread-safe leveled logger. Levels: `off`(0) through `trace`(6). All `LOG_*` calls go through `+[Logger record:file:line:func:newLine:fmt:]` which acquires `@synchronized(self)` on the Logger class. The `_initialized` check is **inside** `@synchronized` to avoid a data race. Output to stderr via `NSFileHandle`. ANSI color auto-detected via `isatty(fileno(stderr))`. Compile-time features: `LOG_SHOW_SOURCE_LOCATION` (file:line:func), `LOG_SHOW_TIME_STAMP` (HH:MM:SS.uuuuuu). `logErrno` uses `@synchronized` and prints errno number only (avoids thread-unsafe `strerror()`).

### `json_writer.h/.m`

Thin wrapper around `NSJSONSerialization`. Single class method: `+[JSONWriter serialize:]` → `NSData*`. Validates with `isValidJSONObject:` before serializing. No pretty-printing (compact output for NDJSON). No JSON parsing — this project only builds JSON.

### `http_parse.h/.m`

HTTP request parsing. `+[HttpParse recvUntilHeadersDoneWithFD:totalLen:headerEnd:]` reads from socket via `recv()` in a loop, appends to `NSMutableData`, scans for `\r\n\r\n` via `rangeOfData:`. Returns raw buffer + byte-based headerEnd offset. `+[HttpParse parseHeadWithData:headerEnd:]` **finds `\r\n\r\n` in NSString character space** (not using the byte offset) — safe for non-ASCII header values where byte offset ≠ character offset. Parses request line ("METHOD PATH VERSION") and headers into `HttpRequest` object. Limits: 64 KB max headers, 32 max headers, 64-byte max header name, 256-byte max header value.

### `http_response.h/.m`

HTTP response writing. `HttpRequest (Headers)` category adds case-insensitive `headerWithName:`. `+[HttpResponse sendAll:data:]` sends all bytes handling short writes via `send()` loop with `EINTR` retry — returns `BOOL`. `+[HttpResponse sendWithFD:statusCode:statusText:contentType:body:]` writes complete response with `Content-Length` and `Connection: close` using `sendAll`. `+[HttpResponse beginChunkedWithFD:contentType:]` **returns `BOOL`** (NO on client disconnect). `+[HttpResponse writeChunkWithFD:data:]` sends hex-size-prefixed chunks using `sendAll`. `+[HttpResponse endChunksWithFD:]` sends terminating `0\r\n\r\n` using `sendAll`.

### `http_server.h/.m`

Defines `HttpHeader`, `HttpRequest`, `ServerConfig` data types. `+[HttpServer runWithConfig:]` creates TCP socket, validates `setsockopt(SO_REUSEADDR)` return, binds, listens (backlog=16), loops forever in `accept()`. Each connection is **throttled** — waits if ≥64 concurrent threads, then spawns NSThread block. Thread counter uses `NSCondition` for push/pull signaling.

Connection handler (`handleConnectionWithFD:config:`):
1. Sets `SO_RCVTIMEO` (30s) on client socket
2. Extracts client IP via `getpeername`/`inet_ntop`
3. Reads headers via `HttpParse`
4. **Validates `Content-Length`** with `NSScanner` (rejects non-numeric, negative)
5. Reads body, **rejects truncated** (short recv) and oversized (>1 MB)
6. Dispatches by method+path to route handlers

Constants: `kRecvChunk` (4096), `kRecvMaxBodyBytes` (1 MB), `kMaxConcurrentThreads` (64), `kRecvTimeoutSeconds` (30).

### `speech_bridge.h/.m`

Global engine state: `g_engine_lock` (NSLock), `g_synth` (NSSpeechSynthesizer), `g_delegate` (VerbatimSpeechDelegate), `g_current_session` (VerbatimSession). `+initialize` creates the lock. `+resolveVoiceName:` performs case-insensitive match through `[NSSpeechSynthesizer availableVoices]`'s `NSVoiceName` attribute.

`VerbatimSpeechDelegate` implements `NSSpeechSynthesizerDelegate`:

- `willSpeakWord:ofString:` — acquires engine lock, checks `sender != g_synth` (stray callback guard), **pushes event while still holding lock**, releases lock
- `didFinishSpeaking:` — acquires engine lock, checks `sender != g_synth`, **pushes terminal event while holding lock**, clears global state, releases lock

`speakWithSession:text:rate:voiceName:` — acquires lock, resolves voice, creates synth, updates globals, **pushes "started" while holding lock**, releases lock, interrupts previous, starts speaking.

`stop` — acquires lock, saves session, clears globals, **pushes terminal event while holding lock**, releases lock, stops synth.

Lock ordering: `g_engine_lock` → queue `NSCondition`. Consistent everywhere, no deadlock.

### `verbatim_event_queue.h/.m`

Two classes: `VerbatimEventQueue` (internal, owns the queue) and `VerbatimSession` (public wrapper). `VerbatimEventQueue` has `NSCondition *condition`, `NSMutableArray<NSString *> *lines`, `BOOL done`. `pushEvent:terminal:` acquires lock, appends, signals, releases. `nextEvent` acquires lock, waits while empty && !done, pops front, releases. **30-second timeout** on `nextEvent` — if triggered, sets `done = YES` to prevent re-entry on subsequent calls.

Stream lifecycle: empty queue → "started" event → "word" events → "finished" event (terminal) → `nextEvent` returns nil.

### `voices.h/.m`

Runs `/usr/bin/say -v '?'` via `NSTask` + `NSPipe`. **Reads stdout and drains stderr BEFORE `waitUntilExit`** to prevent pipe-buffer deadlock (if `say` writes >64KB to stdout and nobody reads, it blocks on write; `waitUntilExit` then blocks forever). Parses output with regex `^(.+)[[:space:]]{2,}([A-Za-z_-]+)[[:space:]]+#` into `VoiceInfo` objects (name + language). No caching — caching is in `routes.m` via `dispatch_once`.

### `route_helpers.h/.m`

`NSString (RouteHelpers)` category: `isBlank` (empty or whitespace-only). `RouteHelpers` class: `+mapSpeedToRate:` (linear: 1→90 WPM, 10→360 WPM, clamped), `+sendJSONResponseWithFD:statusCode:statusText:object:` (serialize + send, falls back to 500 on failure), `+sendJSONErrorWithFD:statusCode:statusText:message:` (wraps in `{"error":"..."}`).

### `route_speak.h/.m`

POST / handler (Routes category). Validates body non-empty, parses `TTS-Voice`/`TTS-Speed`/`ndjson` headers, maps speed to rate, begins chunked response if ndjson (**checks return value — aborts on failure**), creates `VerbatimSession`, calls `[SpeechBridge speakWithSession:...]`, loops `[session nextEvent]` writing chunks via `sendAll`. **Stream timeout**: estimated speaking time × 3 + 30s (minimum 60s) — breaks loop if exceeded. Non-ndjson path drains events silently, returns `{"status":"done"}`.

### `routes.h/.m`

Simple endpoint handlers: `+stopWithFD:request:clientIP:` (calls `[SpeechBridge stop]`), `+statusWithFD:request:clientIP:` (returns speaking bool), `+voicesWithFD:request:clientIP:` (caches JSON via `dispatch_once`), `+notFoundWithFD:` (404 JSON error).

## Data Flow

### Text input

1. Client sends raw UTF-8 text in `POST /` body
2. Body stored as `NSString` in `HttpRequest.body`
3. Validated for non-empty/non-whitespace
4. Truncated bodies rejected (Content-Length mismatch)

### Voice/speed configuration

1. Headers `TTS-Voice`, `TTS-Speed` parsed from `HttpRequest.headers`
2. `TTS-Speed` (1–10) mapped to WPM (90–360) via `[RouteHelpers mapSpeedToRate:]`
3. `TTS-Voice` resolved to `NSSpeechSynthesizer` voice identifier via case-insensitive lookup

### Event production

1. `NSSpeechSynthesizer` delegate callbacks fire on main thread
2. `willSpeakWord:ofString:` builds `{"event":"word","start":N,"length":N}` — **pushed inside `g_engine_lock`**
3. `didFinishSpeaking:` builds `{"event":"finished","completed":bool}` — **pushed inside `g_engine_lock`**
4. Both push to `VerbatimSession`'s `VerbatimEventQueue` via `pushEvent:terminal:`

### Event consumption

1. Connection thread calls `[session nextEvent]` in a loop
2. `nextEvent` blocks on `NSCondition` until event available or 30s timeout
3. On timeout: sets `done = YES`, returns nil
4. Returns NDJSON string or nil (after terminal event consumed)
5. Connection thread writes each event as a chunked HTTP response chunk via `sendAll`
6. Overall stream deadline checked each iteration (3× estimated speech time + 30s)

### Voice listing

1. First `GET /voices` runs `say -v '?'` via `NSTask`
2. stdout read **before** `waitUntilExit` (deadlock prevention)
3. stderr drained to prevent child blocking on error output
4. Output parsed into `VoiceInfo` objects via regex
5. Serialized to JSON via `[JSONWriter serialize:]`
6. Raw `NSData` cached in `g_voices_json` via `dispatch_once`
7. Subsequent requests send cached bytes directly

## Internal APIs

### SpeechBridge (speech_bridge.h)

```objc
+ (void)speakWithSession:(VerbatimSession *)session
                    text:(NSString *)text
                    rate:(float)rate
               voiceName:(nullable NSString *)voiceName;
+ (void)stop;
+ (BOOL)isSpeaking;
```

### VerbatimSession (verbatim_event_queue.h)

```objc
- (nullable NSString *)nextEvent;              // blocking pull (30s timeout)
- (void)pushEvent:(NSString *)line terminal:(BOOL)terminal;  // push + signal
```

### HttpResponse (http_response.h)

```objc
+ (BOOL)sendAll:(int)fd data:(NSData *)data;
+ (void)sendWithFD:(int)fd statusCode:(int)statusCode statusText:(NSString *)statusText
       contentType:(NSString *)contentType body:(NSData *)body;
+ (BOOL)beginChunkedWithFD:(int)fd contentType:(NSString *)contentType;
+ (void)writeChunkWithFD:(int)fd data:(NSData *)data;
+ (void)endChunksWithFD:(int)fd;
```

### HttpParse (http_parse.h)

```objc
+ (NSData *)recvUntilHeadersDoneWithFD:(int)fd
                              totalLen:(NSUInteger *)totalLen
                             headerEnd:(NSUInteger *)headerEnd;
+ (HttpRequest *)parseHeadWithData:(NSData *)data headerEnd:(NSUInteger)headerEnd;
```

### RouteHelpers (route_helpers.h)

```objc
+ (float)mapSpeedToRate:(int)speed;
+ (void)sendJSONResponseWithFD:(int)fd statusCode:(int)statusCode
                    statusText:(NSString *)statusText object:(id)object;
+ (void)sendJSONErrorWithFD:(int)fd statusCode:(int)statusCode
                 statusText:(NSString *)statusText message:(NSString *)message;
```

### JSONWriter (json_writer.h)

```objc
+ (nullable NSData *)serialize:(id)object;
```

### Voices (voices.h)

```objc
+ (NSArray<VoiceInfo *> *)voicesList;
```

## Configuration

All configuration is via CLI flags (no config file, no env vars):

| Flag          | Property   | Default     | Validation                       |
| ------------- | ---------- | ----------- | -------------------------------- |
| `--host`      | `host`     | `127.0.0.1` | Non-empty, ≤253 chars            |
| `--port`      | `port`     | `5959`      | 1024–65535                       |
| `--rate`      | `rate`     | `175`       | 1–1000 WPM, not NaN              |
| `--log-level` | `logLevel` | `info`      | off\|fatal\|error\|warn\|info\|debug\|trace |

`ServerConfig` is heap-allocated in `main.m` and passed to the HTTP server thread.

## Build Pipeline

1. Makefile auto-discovers `src/*.m` via `$(wildcard src/*.m)`
2. Each `.m` compiled to `build/src/*.o` via `$(CC) $(MFLAGS) -c $< -o $@`
3. All `.o` files linked into `verbatimd` via `$(CC) $(LDFLAGS) -o $@ $(OUT) $(LDLIBS)`
4. No dependency tracking — `make clean` required after header changes
5. GitHub Actions: `.github/workflows/release.yml` builds on release creation, uploads `verbatimd-macos-arm64` as release artifact

## Runtime Model

### Threads

| Thread             | Purpose                                      | Lifetime       |
| ------------------ | -------------------------------------------- | -------------- |
| Main thread        | `CFRunLoopRun()` — speech delegate callbacks | Forever        |
| HTTP server thread | `accept()` loop, spawns connection threads   | Forever        |
| Connection threads | Read request, dispatch, write response       | Per-connection |

### Synchronization primitives

| Primitive                             | Purpose                         | Lock ordering     |
| ------------------------------------- | ------------------------------- | ----------------- |
| `@synchronized(self)` on Logger class | Serialize log output            | Lowest priority   |
| `NSLock g_engine_lock`                | Guard speech engine state       | Acquired first    |
| `NSCondition` in VerbatimEventQueue   | Producer/consumer event queue   | Acquired second   |
| `NSCondition g_threadCond`            | Throttle concurrent connections | Independent       |

Lock ordering is strictly enforced: `g_engine_lock` → `VerbatimEventQueue.condition`. No thread ever acquires them in reverse order. The HTTP server thread's `g_threadCond` is independent (never held alongside `g_engine_lock`).

### Networking

- TCP socket, IPv4, `SO_REUSEADDR` (return value checked)
- `listen(16)` backlog
- `accept()` loop, one `NSThread` per connection
- `SO_RCVTIMEO` 30s on client sockets (slowloris mitigation)
- Max 64 concurrent connection threads (`NSCondition` throttling)
- `SIGPIPE` ignored — `EPIPE` handled at `send()` call site via `sendAll`
- No HTTP keep-alive (`Connection: close` always)
- Short writes handled by `sendAll:data:` loop with `EINTR` retry

### DoS protections

| Protection              | Implementation                                     |
| ----------------------- | -------------------------------------------------- |
| Slowloris               | `SO_RCVTIMEO` 30s on client sockets                |
| Thread exhaustion       | Max 64 concurrent threads, `NSCondition` throttle  |
| Oversized bodies        | `Content-Length` > 1 MB rejected immediately        |
| Malformed Content-Length | Non-numeric/negative values rejected                |
| Truncated bodies        | Short recv (< Content-Length) rejected              |
| NDJSON stream hang      | Overall deadline (3× estimated + 30s, min 60s)     |
| Event queue stall       | `nextEvent` 30s timeout, sets `done = YES`          |

## Error Handling

- **POSIX errors:** `logErrno` saves errno immediately, logs number via `@synchronized` (no `strerror()`)
- **HTTP errors:** JSON responses via `[RouteHelpers sendJSONErrorWithFD:...]` (400, 404, 500)
- **Speech errors:** Terminal events pushed to session queue: `{"event":"error","message":"..."}`
- **Socket errors:** `sendAll` returns BOOL, failures logged as WARN, connection closed (non-fatal)
- **Client disconnect:** `beginChunkedWithFD:` returns NO, caller aborts stream
- **Body truncation:** Requests with mismatched `Content-Length` rejected (400)
- **Oversized bodies:** `Content-Length` > 1 MB rejected immediately (400)
- **Malformed Content-Length:** Non-numeric values rejected (400)

## Logging

All output to stderr via `NSFileHandle`. Thread-safe via `@synchronized`. `_initialized` check inside lock. ANSI color auto-detected via `isatty`. Compile-time features: `LOG_SHOW_SOURCE_LOCATION`, `LOG_SHOW_TIME_STAMP`. `logErrno` prints errno number only (avoids thread-unsafe `strerror()`).

## Memory Ownership

- `ServerConfig` — heap-allocated in `main.m`, referenced by server thread. ARC-managed.
- `NSSpeechSynthesizer` — global, guarded by `g_engine_lock`. Created per speak request, released when superseded or finished.
- `VerbatimSpeechDelegate` — referenced by `g_delegate` while active, released when synth cleared.
- `VerbatimSession` — created per `POST /` request, referenced by connection thread and global state. Released after stream ends.
- `VerbatimEventQueue` — owned by `VerbatimSession` as ivar. Released with session.

## External Dependencies

| Dependency | Purpose                                                             |
| ---------- | ------------------------------------------------------------------- |
| Foundation | Core Objective-C runtime, JSON, string handling, threading          |
| AppKit     | `NSSpeechSynthesizer` (only file: `speech_bridge.m`)                |
| pthread    | Thread support (linked but not directly used — `NSThread` wraps it) |

`speech_bridge.m` is the only file that requires AppKit. The rest of the codebase is Foundation-only in principle.

## Known Limitations

- **macOS only** — `NSSpeechSynthesizer` is an AppKit API. Will not compile on Linux.
- **No HTTPS** — local development tool, binds to 127.0.0.1 only.
- **No test suite** — speech pipeline requires real audio output. Manual curl verification.
- **No env var support** — all config via CLI flags.
- **No hot reload of voices** — voice list cached at first `/voices` call, never refreshed.
- **One utterance at a time** — new requests supersede current speech.
- **`speech_bridge.m` cannot be tested in CI** — depends on AppKit, no mock path.
- **`NSSpeechSynthesizer` deprecated in macOS 14.0** — Apple recommends `AVSpeechSynthesizer`. This project uses the older API for its delegate-based word timing.
- **No WebSocket** — NDJSON streaming via HTTP chunked encoding covers the use case.
- **No HTTP keep-alive** — every request opens and closes a TCP connection.
