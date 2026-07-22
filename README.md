# verbatimd (macOS)

A local text-to-speech server for macOS. Speaks text via `NSSpeechSynthesizer`
(the engine behind `say`) and streams real-time word-boundary events as NDJSON
— enabling per-word highlighting in the browser as words are spoken.

Single binary, no runtime dependencies. 100% Objective-C. Listens on
`127.0.0.1:5959` only.

## Requirements

- macOS with Xcode Command Line Tools (`xcode-select --install`)
- Foundation + AppKit frameworks (ships with macOS)

### System requirements

| Tool          | Version                    | Check command     |
| ------------- | -------------------------- | ----------------- |
| macOS version | macOS Tahoe 26             | `sw_vers`         |
| clang version | Apple clang version 21.0.0 | `clang --version` |

## Build

```sh
make help         # show available targets and build options
make              # release build (-O3)
make debug        # debug build (ASan, UBSan, -g3)
```

## Run

```sh
./verbatimd                              # default: 127.0.0.1:5959
./verbatimd --host 0.0.0.0 --port 8080   # custom bind
./verbatimd --log-level trace            # verbose per-word logging
```

## CLI options

| Flag                | Short | Default     | Description                                               |
| ------------------- | ----- | ----------- | --------------------------------------------------------- |
| `--host HOST`       | `-H`  | `127.0.0.1` | Bind address                                              |
| `--port PORT`       | `-P`  | `5959`      | Listen port                                               |
| `--rate RATE`       | `-R`  | `175`       | Default speaking rate (words/min)                         |
| `--log-level LEVEL` | `-L`  | `info`      | `off`, `fatal`, `error`, `warn`, `info`, `debug`, `trace` |
| `--help`            | `-h`  |             | Print usage                                               |
| `--version`         | `-V`  |             | Print version                                             |

## API

All endpoints accept/return JSON. Every request is logged at INFO level with client IP.

### `POST /`

Speak text. Body is raw UTF-8 text (not JSON).

**Headers:**

| Header      | Required | Description                                                                       |
| ----------- | -------- | --------------------------------------------------------------------------------- |
| `TTS-Voice` | No       | Voice display name (case-insensitive). Falls back to system default if not found. |
| `TTS-Speed` | No       | 1 (slowest) – 10 (fastest). Falls back to `--rate`.                               |
| `ndjson`    | No       | `"true"` (default) or `"false"`.                                                  |

**ndjson=true (default):** Returns `application/x-ndjson` stream. Each line is a JSON event:

```json
{"event":"word","start":0,"length":5}
{"event":"word","start":6,"length":3}
{"event":"finished","completed":true}
```

Events arrive in real-time as the synthesizer speaks, allowing per-word highlighting.

**ndjson=false:** Blocks until speech finishes, then returns:

```json
{"status":"done"}
```

### `POST /stop`

Stop current speech. Returns `{"status":"stopped"}`.

### `GET /status`

Returns `{"speaking": bool}`.

### `GET /voices`

Returns array of available voices:

```json
[{"name":"Albert","language":"en_US"},{"name":"Bad News","language":"en_US"},...]
```

Voice list is cached in RAM after first call.

## Quick test (curl)

Start the server first: `make && ./verbatimd`

```sh
# Check status
curl http://127.0.0.1:5959/status

# List available voices
curl http://127.0.0.1:5959/voices

# Speak text (streams NDJSON events)
curl -N -X POST http://127.0.0.1:5959/ -d "Hello world, this is verbatim."

# Speak with a specific voice and speed
curl -N -X POST http://127.0.0.1:5959/ \
  -H "TTS-Voice: Albert" \
  -H "TTS-Speed: 5" \
  -d "Testing voice and speed settings."

# Speak raw (block until done, no streaming)
curl -X POST http://127.0.0.1:5959/ \
  -H "ndjson: false" \
  -d "This blocks until speech finishes."

# Stop current speech
curl -X POST http://127.0.0.1:5959/stop
```

## Log levels

| Level   | What you see                                                      |
| ------- | ----------------------------------------------------------------- |
| `error` | Fatal errors, synth creation failures                             |
| `warn`  | Voice not found, bad requests                                     |
| `info`  | Every HTTP request (IP + method + path), speech start/stop/finish |
| `debug` | Thread spawn, voice cache hit/miss                                |
| `trace` | Per-word delegate callbacks, stray callback suppression           |

Default `info` gives a clear access log of all activity.

## Format

```sh
make format          # uses .clang-format (tabs, 100-col, pointer-right)
clang-format -i src/*.m src/*.h
```

## Install / uninstall

```sh
make install                          # copies to /usr/local/bin/verbatimd
make install PREFIX="$HOME/.local"    # or custom prefix
make uninstall
```

## Architecture

Thirteen source files, no subdirectories:

```
src/
├── project_config.h       # version string, binary name, shared metadata
├── command_line.h/.m      # argv parsing (this project's own — no argp)
├── log.h/.m               # thread-safe leveled logging with ANSI colour
├── json_writer.h/.m       # JSON serialization via NSJSONSerialization
├── http_parse.h/.m        # HTTP request parsing (recv + parse)
├── http_response.h/.m     # HTTP response writing (plain + chunked)
├── http_server.h/.m       # minimal hand-rolled HTTP/1.1 server (thread-per-connection)
├── voices.h/.m            # GET /voices — shells out to `say -v '?'`, cached
├── route_helpers.h/.m     # shared route utilities (speed mapping, JSON helpers)
├── route_speak.h/.m       # POST / handler (the complex one)
├── speech_bridge.h/.m     # NSSpeechSynthesizer wrapper
├── verbatim_event_queue.h/.m  # thread-safe event queue (NSCondition)
├── routes.h/.m            # the remaining HTTP endpoint handlers
└── main.m                 # entry point: parses args, starts server, runs CFRunLoop
```

**Threading model:** The HTTP server runs on a background thread (`[HttpServer runWithConfig:]` via `NSThread`). Each connection gets its own `NSThread` block. The main thread runs `CFRunLoopRun()` to keep the run loop alive — this is required for `NSSpeechSynthesizer` delegate callbacks (`willSpeakWord`) to fire. This division is load-bearing; do not merge the threads.

**Speech engine:** A single global `NSSpeechSynthesizer` instance, guarded by `NSLock`. One utterance at a time — new requests supersede the current one, and the previous session receives a `finished` event with `completed:false`. The `sender != g_synth` identity check in the delegate prevents stray callbacks from a superseded synthesizer from corrupting a newer request's stream.

## License

MIT — see [LICENSE](LICENSE).

## See Also

- [PROJECT_BRIEF.md](PROJECT_BRIEF.md) — Architecture, module guide, mental model
- [DEV.md](DEV.md) — Developer guide
