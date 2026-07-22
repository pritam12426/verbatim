# verbatim

A local macOS TTS server built on top of `say`/`NSSpeechSynthesizer`, with
real-time, per-word timing delivered over HTTP as NDJSON. 100% Objective-C
— no C++, no external JSON library.

## Building

```sh
make help
make             # release build
make debug       # ASan/UBSan build with source-location + timestamp logging
make install     # installs to $PREFIX/bin (default /usr/local/bin)
```

Requires Xcode command line tools (Foundation + AppKit) — this only
builds and runs on macOS, since `NSSpeechSynthesizer` is an AppKit API.

## Running

```sh
verbatimd --host 127.0.0.1 --port 5959 --rate 175 --log-level info
```

| Flag                    | Default     | Meaning                                                         |
| ----------------------- | ----------- | --------------------------------------------------------------- |
| `-H, --host HOST`       | `127.0.0.1` | Host to bind to                                                 |
| `-P, --port PORT`       | `5959`      | Port to listen on                                               |
| `-R, --rate RATE`       | `175`       | Default speaking rate, words per minute                         |
| `-L, --log-level LEVEL` | `info`      | `off` , `fatal` , `error` , `warn` , `info` , `debug` , `trace` |
| `-h, --help`            |             | Print usage                                                     |
| `-V, --version`         |             | Print version                                                   |

## HTTP API

### `POST /`

Body is the raw text to speak (not JSON). Optional headers:

- `TTS-Voice` — a voice display name, matched case-insensitively against
  the names `GET /voices` returns. Falls back to the system default voice
  if not found (a warning is logged).
- `TTS-Speed` — friendly `1` (slowest) to `10` (fastest) scale, mapped
  linearly onto the underlying words-per-minute rate.
- `ndjson` — `true` (default) streams newline-delimited JSON events as
  they happen; `false` blocks until speaking finishes and returns a
  single JSON object instead.

With `ndjson: true`, the response is `application/x-ndjson`, one JSON
object per line:

```json
{"event":"estimate","word_count":42,"estimated_seconds":16.8}
{"event":"started"}
{"event":"word","start":0,"length":5}
{"event":"word","start":6,"length":7}
{"event":"finished","completed":true}
```

The `estimate` line is sent immediately — before the synthesizer has
spoken a single word — computed from `word_count / rate * 60`. It's a
heuristic (real speech isn't perfectly uniform per word), not a
guarantee, but it's effectively free to compute compared to how long the
speech itself will take.

With `ndjson: false`, the response is a single JSON object once speaking
completes:

```json
{"status":"done","word_count":42,"estimated_seconds":16.8}
```

### `POST /stop`

Stops whatever is currently speaking. `{"status":"stopped"}`.

### `GET /status`

`{"speaking":true|false}`.

### `GET /voices`

`[{"name":"Albert","language":"en_US"}, ...]` — parsed from `say -v '?'`,
cached for the process lifetime.

## Project layout

```
verbatim/
├── Makefile
├── README.md
└── src/
    ├── project_config.h    # version string, binary name, shared metadata
    ├── command_line.h/.m   # argv parsing (this project's own — no argp)
    ├── log.h/.m            # thread-safe leveled logging
    ├── json_writer.h/.m    # JSON *serialization* only, via NSJSONSerialization
    ├── http_server.h/.m    # minimal hand-rolled HTTP/1.1 server
    ├── voices.h/.m         # GET /voices — shells out to `say -v '?'`
    ├── speech_bridge.h/.m  # NSSpeechSynthesizer wrapper + event queue
    ├── routes.h/.m         # the four HTTP endpoints
    └── main.m              # entry point: parses args, starts the server
```

⚠️ `speech_bridge.m` is the one file that can't be compiled or tested
outside macOS (there's no AppKit on Linux/CI), so it's the most
important one to verify with a real build.

---

## License

MIT — see [LICENSE](LICENSE).
