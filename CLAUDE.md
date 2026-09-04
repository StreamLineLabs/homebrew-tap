# CLAUDE.md — Streamline Homebrew Tap

## Overview
Homebrew formula for installing [Streamline](https://github.com/streamlinelabs/streamline) on macOS and Linux.

## Installation
Installation is blocked — deliberately and completely — until the v0.3.0
release archives and their signed SHA256 manifest are published. The generated
region of the formula carries an explicit `disable!` stanza, so stable *and*
`--HEAD` installs both fail closed. Homebrew's head-only fallback is not relied
on: an unqualified `brew install streamline` must never quietly become a source
build. Losing HEAD installation pre-artifact is an accepted trade-off; the
`--with-moonshot` source-build option stays declared throughout, so the HEAD
build contract is intact the moment the blocker is replaced.

## Formula Structure
```
├── streamline.rb            # Homebrew formula (disabled until artifacts exist)
├── scripts/
│   ├── check-formula-metadata.sh  # Offline stable-metadata gate
│   ├── update-formula.sh          # Regenerates the stable stanza
│   ├── validate-formula.sh        # Audits via an ephemeral tap (verified copy)
│   ├── test-formula-options.rb    # Source/HEAD build option contract tests
│   └── test-update-formula.sh     # Hermetic updater fixtures
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
- **Head install**: Builds from source using `cargo build --release` (unavailable
  while the `disable!` blocker is in place). Once the blocker is replaced by a
  verified stable stanza, the supported source-build commands are:
  ```bash
  brew install --HEAD streamlinelabs/tap/streamline
  brew install --HEAD --with-moonshot streamlinelabs/tap/streamline
  ```
- **Build option**: `option "with-moonshot"` is a public contract of this tap.
  For HEAD builds it appends `--features moonshot` to the Cargo arguments
  (semantic search, agent memory, attestation, branches). It is declared after
  the `head do` block and before the generated region, per
  `FormulaAudit/ComponentsOrder`, and it lives outside the
  `STABLE ARTIFACTS BEGIN/END` markers so the updater cannot remove it. Do not
  delete it as cleanup: `make test-options` and `make test` both fail if the
  option or its conditional disappears. Known tradeoff: `option` is rejected for
  `homebrew/core` formulae, so a core submission needs a `deprecated_option`
  migration rather than a silent removal.

## Updating the Formula
Checksums are never written by hand. `scripts/update-formula.sh <version>`
regenerates the region between the `STABLE ARTIFACTS BEGIN/END` markers —
replacing the `disable!` blocker with a verified stanza — and it refuses to
modify the formula unless:
1. the upstream checksum manifest is downloadable,
2. `checksums.txt.sig` and `checksums.txt.pem` verify with Cosign against the
   exact
   `https://github.com/StreamlineLabs/streamline/.github/workflows/release.yml@refs/tags/v<version>`
   certificate identity and GitHub Actions OIDC issuer,
3. every expected archive is listed in the manifest under its exact name,
4. every archive's SHA256 matches the manifest and its members are safe,
5. the fully rendered candidate parses as Ruby and passes
   `check-formula-metadata.sh --mode release` *before* `streamline.rb` is
   touched. The single write is an atomic same-directory rename, so any
   failure or interruption leaves the checked-in formula byte-identical.

The generated region records four artifact URLs and four checksums and **no
`version` stanza**: Homebrew infers the version from
`.../streamline-v<version>-<target>.tar.gz`, so a stanza is redundant, and the
only place the generator could write one is after `head do`, where
`brew style`'s `FormulaAudit/ComponentsOrder` cop rejects it (`version` must
precede `license`). `check-formula-metadata.sh` therefore derives the version
from all four URLs and fails if they disagree, if one is missing, or if an
explicit `version` stanza reappears.

`STREAMLINE_REQUIRE_SIGNATURE` accepts only `0` or `1` and defaults to `1`;
`true`, `yes`, `2` and similar are hard errors rather than guessed. `0` is only
for hermetic fixture tests.

`update-formula.yml` automates this on release events. It installs a pinned
Cosign release and uses the fixed core-workflow certificate identity and GitHub
Actions OIDC issuer; no repository signing key or mutable trust-anchor setting
is required. It validates the result before opening a PR.

## Testing
```bash
make lint                       # ruby -c streamline.rb
make metadata                   # offline stable-metadata gate (pre-artifact)
make metadata MODE=release      # release gate; red until artifacts exist
make test                       # hermetic updater fixtures (no network)
make test-options               # source/HEAD build option contract (no brew)
make audit                      # brew style + offline brew audit via an ephemeral tap
make test-install-head          # brew install --HEAD + brew test; fails while disabled
make test-install-head-moonshot # same with --with-moonshot; fails while disabled
make test-install-stable        # only once release artifacts are published
```
