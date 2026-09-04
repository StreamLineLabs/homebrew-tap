# Homebrew Tap for Streamline

[![CI](https://github.com/streamlinelabs/homebrew-tap/actions/workflows/ci.yml/badge.svg)](https://github.com/streamlinelabs/homebrew-tap/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Homebrew](https://img.shields.io/badge/Homebrew-Tap-FBB040.svg)](https://brew.sh/)
[![Release](https://img.shields.io/github/v/release/streamlinelabs/homebrew-tap?label=release)](https://github.com/streamlinelabs/homebrew-tap/releases)

Official [Homebrew](https://brew.sh) tap for [Streamline](https://github.com/streamlinelabs/streamline) — The Redis of Streaming.

## Installation

> **Status: installation from this tap is currently blocked — on purpose.**
> The v0.4.0 release archives for `streamlinelabs/streamline` have not been
> published, so no verifiable SHA256 checksums exist. Rather than ship
> placeholder or unchecked hashes — or rely on Homebrew quietly falling back to
> a source build — the formula carries an explicit `disable!` stanza. **Every**
> install path fails closed, including `--HEAD`. There is no supported way to
> install Streamline from this tap until the release artifacts and their signed
> checksum manifest exist.
>
> To try Streamline in the meantime, build it from the
> [upstream repository](https://github.com/streamlinelabs/streamline) directly.

### Stable installation (available once v0.4.0 artifacts are published)

Once maintainers have run `./scripts/update-formula.sh 0.4.0` against the
published, signed release, the blocker is replaced by verified artifact URLs and
checksums and the normal commands work:

```bash
brew tap streamlinelabs/tap
brew install streamline
```

Or, in one command:

```bash
brew install streamlinelabs/tap/streamline
```

A `--HEAD` build (which compiles from source and requires Rust, installed
automatically as a build dependency) becomes available at the same time:

```bash
brew install --HEAD streamlinelabs/tap/streamline
```

### Experimental moonshot features (source builds only)

The tap publishes one build option, `--with-moonshot`, which compiles
Streamline's experimental moonshot features (semantic search, agent memory,
attestation, branches) by passing `--features moonshot` to Cargo. It applies to
source builds only — bottles and release archives are always built without it —
and, like every other install path, it is blocked until the release artifacts
and their signed manifest exist:

```bash
brew install --HEAD --with-moonshot streamlinelabs/tap/streamline
```

This option is a public interface of the tap: it is documented, tested
(`make test-options`), and deliberately preserved rather than dropped during
cleanups, because removing it would turn a documented command into an "invalid
option" error for existing users and scripts. Known tradeoff: Homebrew
discourages `option` in `homebrew/core` formulae (its `FormulaAudit/Options`
cop reports it there), so a future homebrew-core submission would have to
migrate the flag — with a `deprecated_option` cycle — rather than delete it
silently. `brew audit --strict` does not flag it for this tap, and the contract
is kept until that migration is actually performed.

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
streamline --data-dir "$(brew --prefix)/var/streamline"

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
| `$(brew --prefix)/var/streamline/` | Data directory |
| `$(brew --prefix)/var/log/streamline.log` | Log file |

## Troubleshooting

### `brew install` Reports That the Formula Is Disabled

That is the intended, documented state. The formula deliberately records no
stable artifacts until the release's `checksums.txt`, keyless Cosign
`checksums.txt.sig`/`.pem`, and v-prefixed archives are published; there is
nothing to verify against, so no install can be
authenticated. The `disable!` stanza makes that explicit instead of letting an
unqualified `brew install streamline` silently resolve to a HEAD source build.

`brew install --HEAD` is blocked for the same reason, with or without
`--with-moonshot`. There is no flag or workaround that re-enables it, and
adding one would defeat the purpose.

Once the release is published, maintainers regenerate the stable stanza with
`./scripts/update-formula.sh 0.4.0`, which removes the blocker as part of
writing verified URLs and checksums; then `brew update && brew install
streamline` works normally.

### Service Won't Start

Check the log file for errors:

```bash
tail -50 "$(brew --prefix)/var/log/streamline.log"
```

Ensure the data directory exists and is writable:

```bash
mkdir -p "$(brew --prefix)/var/streamline"
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
rm -rf "$(brew --prefix)/var/streamline"
mkdir -p "$(brew --prefix)/var/streamline"
brew services start streamline
```

## Formula Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for development instructions.

### Quick Validation

```bash
make lint                     # Ruby syntax check
make metadata                 # Offline stable-metadata gate (pre-artifact)
make metadata MODE=release    # Release gate; red until artifacts exist
make test                     # Hermetic updater fixtures (no network)
make test-options             # Source/HEAD build option contract (no brew, no network)
make audit                    # brew style + offline brew audit via an ephemeral tap
```

`make audit` builds a throwaway tap, copies `streamline.rb` into it and `cmp`s
the copy against the working-tree file before and after the brew steps, so
Homebrew audits a tapped formula that is provably the exact file in this tree.
(A symlink cannot be used: Homebrew realpath-resolves the formula and rejects
one that resolves back out of the tap.) The install targets
(`make test-install-head`, `make test-install-head-moonshot`,
`make test-install-stable`) go through the same tap and are expected to fail
while the formula is disabled.

## License

Apache-2.0
<!-- refactor: 61f2f890 -->
<!-- docs: 037adec4 -->
<!-- chore: 51a2c084 -->
