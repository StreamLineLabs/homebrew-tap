# Contributing to Homebrew Tap for Streamline

Thank you for your interest in contributing! Please review the [organization-wide contributing guidelines](https://github.com/streamlinelabs/.github/blob/main/CONTRIBUTING.md) first.

## Formula Updates

The formula is automatically updated when new Streamline releases are published via the "Update Formula" GitHub Action. To update manually:

```bash
# Update formula with release artifact hashes
./scripts/update-formula.sh <version>

# Preview changes without modifying files
./scripts/update-formula.sh <version> --dry-run

# Update and create a PR automatically
./scripts/update-formula.sh <version> --create-pr
```

## Development

### Prerequisites

- [Homebrew](https://brew.sh)
- Ruby (comes with macOS)
- [GitHub CLI](https://cli.github.com/) (`gh`) — only needed for `--create-pr`

### Local Testing

```bash
# Lint the formula (Ruby syntax + Homebrew audit)
make lint
make audit

# Full install + test cycle (requires release artifacts)
make test-install

# Or manually:
brew tap-new streamlinelabs/test --no-git
cp streamline.rb "$(brew --repository streamlinelabs/test)/Formula/streamline.rb"
brew install streamlinelabs/test/streamline
brew test streamlinelabs/test/streamline
brew audit --strict --formula streamlinelabs/test/streamline
```

### Testing HEAD Builds (from source)

```bash
brew install --HEAD streamlinelabs/tap/streamline
```

This builds from the `main` branch and requires Rust.

## Homebrew-core Submission Checklist

When the formula is ready for submission to [homebrew-core](https://github.com/Homebrew/homebrew-core):

- [ ] Formula passes `brew audit --strict --online`
- [ ] Formula passes `brew test`
- [ ] No custom download strategies
- [ ] Stable URL points to a versioned release (not `HEAD`)
- [ ] SHA256 hashes are real (no placeholders)
- [ ] Test block verifies `--version` output
- [ ] `desc` is concise and starts with a capital letter
- [ ] `homepage` is a valid, accessible URL
- [ ] License is declared and matches the project
- [ ] No `bottle :unneeded` (homebrew-core builds its own bottles)
- [ ] Binary names don't conflict with existing formulae
- [ ] Significant user base / project notability (500+ GitHub stars recommended)

### Key Differences from Tap Formula

For homebrew-core submission, the formula would need:

1. **Remove `bottle :unneeded`** — homebrew-core builds and hosts its own bottles
2. **Build from source** — use the `head` block pattern as the main `stable` block with Rust build
3. **Remove platform-specific URL blocks** — homebrew-core handles multi-platform via bottles
4. **Ensure `brew audit --strict --online` passes** with zero warnings

## CI Pipeline

Pull requests are tested by GitHub Actions:

| Job | Runner | What it tests |
|---|---|---|
| Formula Lint | macOS (ARM64) | Ruby syntax, `brew audit`, `brew style` |
| Test macOS ARM64 | macOS 14 (ARM64) | `brew install` + `brew test` on Apple Silicon |
| Test macOS Intel | macOS 13 (Intel) | `brew install` + `brew test` on Intel |
| Test Linux | Ubuntu (x86_64) | `brew install` + `brew test` on Linuxbrew |
| Head Build | macOS (ARM64) | `brew install --HEAD` from source (main branch only) |

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 License.
