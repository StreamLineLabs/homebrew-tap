# CLAUDE.md — Streamline Homebrew Tap

## Overview
Homebrew formula for installing [Streamline](https://github.com/streamlinelabs/streamline) on macOS and Linux.

## Installation
```bash
brew install streamlinelabs/tap/streamline
```

## Formula Structure
```
├── streamline.rb            # Homebrew formula
├── scripts/                 # Helper scripts
├── .github/workflows/
│   ├── ci.yml               # Formula validation
│   ├── release-drafter.yml
│   └── update-formula.yml   # Auto-update on new releases
```

## Formula Details
- **Binaries**: `streamline` (server) + `streamline-cli` (CLI tool)
- **Platforms**: macOS ARM64, macOS x86_64, Linux ARM64, Linux x86_64
- **Service**: Managed via `brew services` (launchd on macOS, systemd on Linux)
- **Data directory**: `#{var}/streamline`
- **Log file**: `#{var}/log/streamline.log`
- **Head install**: Builds from source using `cargo build --release`

## Updating the Formula
When a new Streamline version is released:
1. Update version and SHA256 checksums in `streamline.rb`
2. Update download URLs to point to new release assets
3. Test with `brew install --build-from-source streamlinelabs/tap/streamline`
4. The `update-formula.yml` workflow can automate this on release events

## Testing
```bash
brew audit --strict streamlinelabs/tap/streamline    # Lint formula
brew test streamlinelabs/tap/streamline              # Run formula tests
```
