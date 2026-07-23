# verbatimd

A local text-to-speech server for macOS. Sends text to `NSSpeechSynthesizer` (the engine behind the `say` command) and streams real-time per-word timing events as NDJSON over HTTP — enabling word-by-word highlighting in the browser as words are spoken.

Single binary. 100% Objective-C. No runtime dependencies. Binds to `127.0.0.1:5959` by default.

## Requirements

- macOS — the only dependency. Ships with every Mac.

## Install

Download the latest pre-compiled binary (no build tools needed):

```sh
mkdir -p ~/.local/bin
curl -fL --progress-bar https://github.com/pritam12426/verbatim/releases/latest/download/verbatimd-macos-arm64 -o ~/.local/bin/verbatimd
chmod +x ~/.local/bin/verbatimd
```

Add `~/.local/bin` to your `PATH` if it isn't already:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

### From source

Requires Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/pritam12426/verbatim.git
cd verbatim
make                              # release build → ./verbatimd
make install                      # copies to /usr/local/bin/verbatimd
make install PREFIX="$HOME/.local" # or custom prefix
```

## Quick start

```sh
verbatimd &

# Speak text (streams per-word events in real time)
curl -N -X POST http://127.0.0.1:5959/ -d "Hello world, this is verbatim."

# Stop speaking
curl -X POST http://127.0.0.1:5959/stop

# Check status
curl http://127.0.0.1:5959/status

# List voices
curl http://127.0.0.1:5959/voices
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

All endpoints accept/return JSON. Every request is logged at INFO level with the client IP.

### POST /

Speak text. Body is raw UTF-8 text (not JSON).

**Headers:**

| Header      | Required | Description                                                                       |
| ----------- | -------- | --------------------------------------------------------------------------------- |
| `TTS-Voice` | No       | Voice display name (case-insensitive). Falls back to system default if not found. |
| `TTS-Speed` | No       | 1 (slowest) – 10 (fastest). Falls back to `--rate`.                               |
| `ndjson`    | No       | `"true"` (default) or `"false"`.                                                  |

**ndjson=true (default):** Returns `application/x-ndjson` stream. Each line is a JSON event:

```json
{"event":"started"}
{"event":"word","start":0,"length":5}
{"event":"word","start":6,"length":3}
{"event":"finished","completed":true}
```

Events arrive in real time as the synthesizer speaks, allowing per-word highlighting.

**ndjson=false:** Blocks until speech finishes, then returns:

```json
{"status":"done"}
```

### POST /stop

Stop current speech. Returns `{"status":"stopped"}`.

### GET /status

Returns `{"speaking": bool}`.

### GET /voices

Returns array of available voices:

```json
[{"name":"Albert","language":"en_US"},{"name":"Bad News","language":"en_US"}]
```

Voice list is cached in RAM after first call.

## Examples

```sh
# ── Basic usage ──────────────────────────────────────────────────────────────

# Speak text (streams NDJSON events in real time)
curl -N -X POST http://127.0.0.1:5959/ -d "Hello world, this is verbatim."

# Stop speaking
curl -X POST http://127.0.0.1:5959/stop

# Check if speaking
curl http://127.0.0.1:5959/status

# List available voices
curl http://127.0.0.1:5959/voices

# ── Voice and speed ─────────────────────────────────────────────────────────

# Speak with a specific voice
curl -N -X POST http://127.0.0.1:5959/ \
  -H "TTS-Voice: Albert" \
  -d "Hello, I am Albert."

# Speak with voice and speed
curl -N -X POST http://127.0.0.1:5959/ \
  -H "TTS-Voice: Samantha" \
  -H "TTS-Speed: 8" \
  -d "This is spoken very fast."

# Speed only (use default voice)
curl -N -X POST http://127.0.0.1:5959/ \
  -H "TTS-Speed: 2" \
  -d "This is spoken slowly."

# ── Non-streaming mode ──────────────────────────────────────────────────────

# Block until speech finishes, get a single JSON response
curl -X POST http://127.0.0.1:5959/ \
  -H "ndjson: false" \
  -d "This blocks until speech finishes."

# Non-streaming with voice and speed
curl -X POST http://127.0.0.1:5959/ \
  -H "TTS-Voice: Albert" \
  -H "TTS-Speed: 5" \
  -H "ndjson: false" \
  -d "Blocking with custom voice and speed."

# ── Error cases ─────────────────────────────────────────────────────────────

# Empty body → 400
curl -X POST http://127.0.0.1:5959/ -d ""

# Unknown route → 404
curl http://127.0.0.1:5959/nonexistent
```

## Build variants

```sh
make help     # show all targets and build options
make          # release (-O3)
make debug    # debug (ASan + UBSan, -g3)
make clean    # remove build artifacts
make format   # auto-format with .clang-format (tabs, 100-col, pointer-right)
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

## License

MIT — see [LICENSE](LICENSE).

## See also

- [DEV.md](DEV.md) — developer guide, architecture overview, API reference
- [PROJECT_BRIEF.md](PROJECT_BRIEF.md) — complete codebase reference for contributors and AI agents
