# DEV.md — Developer Guide

> High-level orientation for working on `verbatim`. For the full module-by-module
> mind map, see [`PROJECT_BRIEF.md`](./PROJECT_BRIEF.md). For the HTTP API as a
> consumer, see [`README.md`](./README.md).

---

## What this is

A local macOS TTS server: `POST` text to it, get back real-time,
per-word timing events as it's spoken aloud via `NSSpeechSynthesizer`.
Single-purpose tool, not a framework — no plugins, no config file, no
runtime extensibility. Everything is a CLI flag.

100% Objective-C. No C++, no external libraries (no `cJSON`, no `argp`)
— just Foundation, AppKit, and POSIX.

## Requirements

- macOS with Xcode command line tools (`xcode-select --install`)
- That's it. No Homebrew dependencies, no package manager.

`NSSpeechSynthesizer` is an AppKit API, so this cannot be built or run on
Linux — unlike the old `verbatim_ojb_cpp_C` project, which split its
logic so most of it _could_ be curl-tested on Linux via a mock backend.
This rewrite keeps that same split (see [Architecture](#architecture-at-a-glance)),
so most of the codebase is still Linux-buildable in principle — only
`speech_bridge.m` actually requires macOS to compile.

## Getting started

```sh
git clone <repo> && cd verbatim
make                                    # release build -> ./verbatimd
```

Other useful variants:

```sh
make debug O_DEBUG=1     # ASan + UBSan, -g3, source-location + timestamp logging
make clean                # remove build artifacts
make install               # copies to $PREFIX/bin (default /usr/local/bin)
```

Run it and poke it with curl:

```sh
./verbatimd --log-level debug &
curl -X POST localhost:5959/ -d "hello from verbatim"
curl localhost:5959/status
curl localhost:5959/voices
curl -X POST localhost:5959/stop
```

## Architecture at a glance

```
main thread                          background thread             per-connection threads
────────────                         ──────────────────             ───────────────────────
command_line.m: parse argv           http_server_run():             handle_connection():
log.m: [Logger init:]                socket/bind/listen/accept  ──▶  parse request
build ServerConfig                   loop forever, spawning           dispatch to routes.m
pthread_create(server_thread) ──────▶ one detached pthread            (route_speak may talk
                                       per connection                  to speech_bridge.m,
CFRunLoopRun()  ◀── blocks forever,                                   which owns a single,
   required so AppKit can                                             global NSSpeechSynthesizer)
   deliver NSSpeechSynthesizer
   delegate callbacks
   (willSpeakWord, etc.)
```

**The one rule that shapes everything else:** `NSSpeechSynthesizer`'s
delegate callbacks only fire if a run loop is alive on _some_ thread
tracking that synthesizer's runtime, and in practice that means the main
thread needs to be the one running the loop. That's why `main()` never
does real work itself — it hands off to a background thread and then
blocks forever on `CFRunLoopRun()`. (This is also, per the original
project's history, the exact guarantee an async Swift `main()` broke —
see `PROJECT_BRIEF.md` §1 for that backstory.)

Everything downstream of the accept loop is plain, boring, blocking I/O
on its own thread — there's no async runtime, no reactor, no thread
pool. One thread per HTTP connection, and exactly one global speech
engine shared across all of them (starting a new utterance interrupts
whatever was previously speaking, matching the single-utterance-at-a-time
behavior of the original Swift version).

## Source tree

| File                 | Responsibility                                                               |
| -------------------- | ---------------------------------------------------------------------------- |
| `project_config.h`   | Version string, binary name, shared string constants                         |
| `command_line.h/.m`  | `argv` → `CommandLineArguments` (this project's own parser, no `argp`)       |
| `log.h/.m`           | Thread-safe leveled logger (`Logger` class + `LOG_*` macros)                 |
| `json_writer.h/.m`   | JSON _serialization only_, via `NSJSONSerialization`                         |
| `http_server.h/.m`   | Hand-rolled HTTP/1.1: socket accept loop, request parsing, chunked responses |
| `voices.h/.m`        | `GET /voices` — shells out to `say -v '?'`, parses + caches                  |
| `speech_bridge.h/.m` | Wraps `NSSpeechSynthesizer`; per-session NDJSON event queue                  |
| `routes.h/.m`        | The four HTTP endpoints                                                      |
| `main.m`             | Entry point: parse args, start server thread, block on the run loop          |

Flat `src/`, no subdirectories — same convention as the old project.

## How a request flows (short version)

1. `http_server_run()` accepts a connection, spawns a detached pthread.
2. That thread reads/parses the request (`http_server.m`), then dispatches
   by method+path to a `route_*` function (`routes.m`).
3. `route_speak` (the only interesting one): validates the body, reads
   `TTS-Voice`/`TTS-Speed`/`ndjson` headers, computes a word-count-based
   duration estimate, creates a `VerbatimSession`, and calls
   `verbatim_speak()`.
4. `speech_bridge.m` interrupts whatever was previously speaking,
   creates a new `NSSpeechSynthesizer`, and starts it. Its delegate
   pushes `word`/`finished` events onto the session's queue as AppKit
   calls back (on the main thread's run loop).
5. Back in `route_speak`, the connection thread blocks on
   `verbatim_next_event()` in a loop, writing each event out as an NDJSON
   chunk until the terminal event arrives.
6. Connection closes (`Connection: close` always — no keep-alive).

Full detail, including every module's internals, is in
`PROJECT_BRIEF.md` §4–5.

## Design philosophy

- **CLI-only config.** No config file, no env vars.
- **No hidden concurrency.** Thread-per-connection, no thread pool, no
  async runtime — you can reason about every thread that exists.
- **No JSON parsing.** The server only ever _emits_ JSON; every input
  either arrives as raw body text or an HTTP header.
- **One utterance at a time**, globally — matches the original Swift
  version's behavior rather than trying to multiplex multiple
  simultaneous speech sessions.
- **Proven code stays put.** Where a piece of logic was already
  carefully verified (the `voices.m` regex, the HTTP parsing), it was
  kept as-is during the Objective-C rewrite rather than modernized for
  its own sake — see `PROJECT_BRIEF.md` §8 for the specific calls made.

## Contributing — common changes

| Task                     | Files to touch                                                                                                                     |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Add a CLI flag           | `command_line.h/.m` (parsing + property), `main.m` (wire into `ServerConfig`)                                                      |
| Add an HTTP endpoint     | `routes.h/.m` (new `route_*` function), `http_server.m` (dispatch in `handle_connection`)                                          |
| Add a log level          | `log.h` (enum + macro), `log.m` (`defaultLogHandler:`/`colorLogHandler:`)                                                          |
| Change JSON output shape | `routes.m` only — build a different `NSDictionary`/`NSArray` literal                                                               |
| Touch the speech engine  | `speech_bridge.m` — the one file you can't test outside macOS; build and manually verify with `curl` before trusting a change here |

Coding conventions already in place, worth matching: tabs for
indentation, opening braces on the same line, `snake_case` for plain C
functions (`http_get_header`, `verbatim_speak`), `camelCase` for
Objective-C methods/properties, and a comment above every non-obvious
function explaining _why_, not just what.

## Known limitations

No TLS, no HTTP/2, no keep-alive, no automated test suite yet. Full
rationale for each in `PROJECT_BRIEF.md` §9–10.
