# Homebrew Tap for Streamline

[![CI](https://github.com/streamlinelabs/homebrew-tap/actions/workflows/ci.yml/badge.svg)](https://github.com/streamlinelabs/homebrew-tap/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Homebrew](https://img.shields.io/badge/Homebrew-Tap-FBB040.svg)](https://brew.sh/)

Official [Homebrew](https://brew.sh) tap for [Streamline](https://github.com/streamlinelabs/streamline) — The Redis of Streaming.

## Installation

```bash
brew tap streamlinelabs/tap
brew install streamline
```

Or install directly in one command:

```bash
brew install streamlinelabs/tap/streamline
```

### Install from HEAD (build from source)

```bash
brew install --HEAD streamlinelabs/tap/streamline
```

This requires Rust to be installed (Homebrew will install it automatically as a build dependency).

## Upgrade

```bash
brew update
brew upgrade streamline
```

## Uninstall

```bash
brew services stop streamline   # if running as a service
brew uninstall streamline
brew untap streamlinelabs/tap   # optional: remove the tap
```

## Usage

### Start the Server

```bash
# Start in foreground
streamline --data-dir /usr/local/var/streamline

# Start in playground mode (in-memory, demo topics)
streamline --playground
```

### Service Management (macOS launchd / Linux systemd)

```bash
# Start as a background service
brew services start streamline

# Stop the service
brew services stop streamline

# Restart the service
brew services restart streamline

# Check service status
brew services list | grep streamline
```

### CLI

```bash
# Produce a message
streamline-cli produce demo -m "Hello, Streamline!"

# Consume messages
streamline-cli consume demo --from-beginning

# List topics
streamline-cli topics list
```

### Kafka Compatibility

Streamline is Kafka protocol-compatible. Connect any Kafka client to `localhost:9092`.

## File Locations

| Path | Description |
|---|---|
| `$(brew --prefix)/bin/streamline` | Server binary |
| `$(brew --prefix)/bin/streamline-cli` | CLI binary |
| `/usr/local/var/streamline/` | Data directory |
| `/usr/local/var/log/streamline.log` | Log file |

## Troubleshooting

### Installation Fails with SHA256 Mismatch

The formula may have placeholder hashes if the release artifacts haven't been published yet. Wait for the release to complete and retry:

```bash
brew update
brew install streamline
```

### Service Won't Start

Check the log file for errors:

```bash
tail -50 /usr/local/var/log/streamline.log
```

Ensure the data directory exists and is writable:

```bash
mkdir -p /usr/local/var/streamline
```

### Port Already in Use

Streamline defaults to port 9092. If another process (e.g., Apache Kafka) is using it:

```bash
lsof -i :9092
```

### brew doctor Warnings

Run `brew doctor` to check for common Homebrew issues:

```bash
brew doctor
```

### Reset to Clean State

```bash
brew services stop streamline
rm -rf /usr/local/var/streamline/*
brew services start streamline
```

## Formula Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development instructions.

### Quick Validation

```bash
make lint          # Ruby syntax check
make audit         # Homebrew audit (strict)
make test-install  # Full install + test cycle
```

## License

Apache-2.0
<!-- refactor: 61f2f890 -->
<!-- docs: 037adec4 -->
<!-- chore: 51a2c084 -->

<!-- add tap installation troubleshooting notes -->

