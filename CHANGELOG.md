# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]
- **Fixed**: resolve dependency conflict with openssl@3
- **Documentation**: add caveats section for Apple Silicon users
- **Changed**: update formula version to latest stable
- **Fixed**: correct sha256 checksum for latest release

### Added
- Post-install verification step

### Fixed
- Correct bottle hash for arm64 darwin
- Correct version constraint in formula

## [0.2.0] - 2026-02-18

### Added
- Homebrew formula for Streamline server
- 4-architecture support (macOS/Linux, x86_64/ARM64)
- `brew services` integration for background server management
- Automated formula update workflow
- Cask support for macOS
