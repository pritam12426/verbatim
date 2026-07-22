# main-binary

> A fast & lightweight ............

`main-binary` is a small C program that lets you declare .............

---

## Requirements

- **C17** compiler (gcc or clang)
- **argp** — built into glibc on Linux; install via `brew install argp-standalone` on macOS

---

## Build

```sh
make                                # optimised release build -O3
make debug -B O_DEBUG=1             # debug build with -g3 -DDEBUG
make install                        # install to /usr/local/bin (use PREFIX= to override)
make install PREFIX="$HOME/.local"  # install to $HOME/.local
make clean
```

## Usage

```
main-binary [OPTION...] [TARGET(s)...]
```

### Options

| Flag          | Short | Place shoulder | Description                                                   |
| ------------- | ----- | -------------- | ------------------------------------------------------------- |
| `--dry-run`   | `-n`  | —              | Show what would change without making any changes             |
| `--log-level` | `-L`  | `LEVEL`        | Set log verbosity: `error`, `warn`, `info` (default), `debug` |
| `--log-file`  | `-F`  | `FILE`         | Set logging file                                              |

### Examples

```sh
# See what would be synced without making changes
main-binary --dry-run

# Verbose debug output
main-binary --log-level debug
```

---

## Project structure

```
./main-binary
└── src/
│   ├── main.c            # CLI argument parsing, sync loop
│   ├── log.h             # LOG_ERROR / LOG_WARN / LOG_INFO / LOG_DEBUG macros
│   ├── log.c             # log_record() implementation
│   └── project_config.h  # Version, name, global rclone options
└── Makefile
```

---

## License

See [LICENSE](LICENSE).
