# verbatim

**verbatim** is a small, dependency-light local server for macOS that wraps
`NSSpeechSynthesizer` — the same native engine behind the `say` command —
and streams real, per-word timing events over HTTP as text is spoken. Unlike
`say`, which only gives you audio, `verbatim` tells a client exactly which
word is being spoken, live, so a UI can highlight along in real time.

Built in C and Objective-C++ (`verbatimd`, the server binary) with no
Node.js, no Swift runtime, and no async-framework overhead — just sockets,
a small HTTP layer, and a direct call into AppKit's speech engine.

## Build

```sh
make help                           # show available targets
make                                # optimised release build -O3
make debug                          # debug build
make install                        # install to /usr/local/bin (use PREFIX= to override)
make install PREFIX="$HOME/.local"  # install to $HOME/.local
make clean
```

## Usage

```
verbatimd [OPTIONS] 
verbatimd - local macOS TTS server over say command with real-time, per-word timing over HTTP

Options:
  -H, --host HOST         Host to bind to (default: 127.0.0.1)
  -P, --port PORT         Port to listen on (default: 5959)
  -R, --rate RATE         Default speaking rate, in words per minute (default: 175)
  -L, --log-level LEVEL   Log level: [off|trace|debug|info|warn|error|fatal] (default: info)
  -h, --help              Print this help message
  -V, --version           Print version information
```

### Options

| Flag          | Short | Place shoulder | Description                                                                           |
| ------------- | ----- | -------------- | ------------------------------------------------------------------------------------- |
| `--host`      | `-H`  | `HOST`         | Host to bind to (default: `127.0.0.1`)                                                |
| `--port`      | `-P`  | `PORT`         | Port to listen on (default: `5959`)                                                   |
| `--rate`      | `-R`  | `RATE`         | Default speaking rate, in words per minute (default: `175`)                           |
| `--log-level` | `-L`  | `LEVEL`        | Set log level: `off`, `trace`,`debug`,`info`,`warn`,`error`,`fatal` (default: `info`) |
| `--version`   | `-V`  | —             | Print version information                                                             |
| `--help`      | `-h`  | —             | Print this help message                                                               |

### Examples

```sh
# Verbose debug output
verbatimd --log-level trace
```

---

## Project structure

```
./verbatim
└── src
│   ├── command_line.h
│   ├── command_line.m
│   ├── log.h
│   ├── log.m
│   ├── main.m
│   └── project_config.h
└── Makefile
```

---

## License

MIT — see [LICENSE](LICENSE).
