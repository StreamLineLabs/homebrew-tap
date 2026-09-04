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
# Ruby syntax
make lint

# Offline stable-metadata gate (never touches the network or Homebrew)
make metadata                 # pre-artifact: the current, blocked state
make metadata MODE=release    # release gate: red until artifacts exist

# Hermetic updater tests (local file:// fixtures, no network, no install)
make test

# Source/HEAD build option contract (loads the formula against a stub
# Homebrew DSL and runs its real `install`; no brew, no network)
make test-options

# brew style + offline brew audit, via an ephemeral tap
make audit
```

`make audit` runs `scripts/validate-formula.sh`, which creates a throwaway tap
(`streamlinelabs-validate/local`) and **copies** `streamline.rb` into it. A
symlink is not usable here: Homebrew resolves the formula path through
`realpath` before deciding whether it lives in a tap, so a link pointing back
into your checkout is rejected with "Homebrew requires formulae to be in a
tap" — exactly like a bare path. To keep the copy from becoming a source of
false confidence, the script `cmp`s it against `streamline.rb` immediately
after copying *and* again after `brew style`/`brew audit` (and after install
and test, when those run); any divergence in either direction aborts the run.
The tap is removed on exit, including on failure. Do not copy the formula into
a tap by hand and do not audit it by bare path — path mode skips several audits
that only apply to tapped formulae, and current Homebrew refuses it outright.

### Install and test

```bash
make test-install-head           # brew install --HEAD + brew test
make test-install-head-moonshot  # brew install --HEAD --with-moonshot + brew test
make test-install-stable         # brew install + brew test (needs release artifacts)
```

**All three currently fail, on purpose.** Until the upstream release archives
and their signed SHA256 manifest exist, the formula's generated region carries a
`disable!` stanza that blocks every install path, `--HEAD` included. Do not
remove the blocker to make these pass; it is removed only by
`scripts/update-formula.sh` as part of writing verified URLs and checksums.
To try Streamline meanwhile, build it from the
[upstream repository](https://github.com/streamlinelabs/streamline).

Once the artifacts are published, the source-build commands these targets wrap
are exactly:

```bash
brew install --HEAD streamlinelabs/tap/streamline
brew install --HEAD --with-moonshot streamlinelabs/tap/streamline
```

### The `--with-moonshot` build option

`streamline.rb` declares `option "with-moonshot"`, and `install` appends
`--features moonshot` to the Cargo arguments for HEAD builds when it is
requested. This is a **public build contract**, not leftover code:

- it is documented in the README and exercised by `make test-options`, which
  runs the formula's real `install` method against a stub Homebrew DSL and
  asserts that a plain HEAD build passes no feature flag while
  `--with-moonshot` appends `--features moonshot` exactly once, immediately
  after the standard Cargo arguments;
- `make test` additionally re-runs that contract against a *regenerated*
  formula, so `scripts/update-formula.sh` cannot quietly drop it (the option and
  the conditional live outside the `STABLE ARTIFACTS` markers on purpose);
- placement follows `FormulaAudit/ComponentsOrder`: `option` sits after the
  `head do` block and before `disable!`/`on_macos`/`on_linux`.

Known tradeoff: Homebrew's `FormulaAudit/Options` cop reports `option` usage for
`homebrew/core` formulae. It does not fire for this tap (the check returns early
unless the formula's tap is `homebrew-core`), so `brew audit --strict` stays
green here. If the formula is ever submitted to homebrew-core, the flag must be
migrated through `deprecated_option` and an upstream deprecation notice — do not
delete it as "cleanup", which would break documented user commands without
warning.

### Updating the stable stanza

Checksums are never hand-written:

```bash
./scripts/update-formula.sh 0.3.0
```

Signature verification is required by default. `STREAMLINE_REQUIRE_SIGNATURE`
accepts only `0` or `1`, and `0` is reserved for the hermetic fixture tests.
Production verification consumes the core release's `checksums.txt`,
`checksums.txt.sig`, and `checksums.txt.pem` and pins the exact
`https://github.com/StreamlineLabs/streamline/.github/workflows/release.yml@refs/tags/v<version>`
certificate identity plus the GitHub Actions OIDC issuer.

The generated stanza carries four artifact URLs and four checksums but no
`version` stanza. Homebrew infers the version from
`.../streamline-v<version>-<target>.tar.gz`, so an explicit stanza is redundant,
and the only position the generator could use — after `head do` — is rejected
by `brew style` (`FormulaAudit/ComponentsOrder`: `version` must come before
`license`). `make metadata` derives the version from all four URLs instead and
fails if they disagree or if a `version` stanza is added back.

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
4. **Migrate `option "with-moonshot"`** — homebrew-core does not accept `option`
   (`FormulaAudit/Options`). Migrating means a `deprecated_option` cycle plus an
   upstream announcement, not deleting the flag: it is a documented command in
   this tap and vanishing it would break users silently.
5. **Ensure `brew audit --strict --online` passes** with zero warnings

## CI Pipeline

Pull requests are tested by GitHub Actions:

| Job | Runner | What it tests |
|---|---|---|
| `validate` | macOS | Ruby + shell syntax, offline stable-metadata gate, hermetic updater tests, source/HEAD option contract tests, `brew style` and offline `brew audit` through an ephemeral tap |
| `release-gate` | Ubuntu | Advisory mirror of the tag-time gate; red until real artifact URLs and hashes exist, and non-blocking for day-to-day pushes |

No job installs the formula: while the `disable!` blocker is in place there is
nothing installable, and audits are deliberately offline (no `--online`, no
release artifact is fetched). Install/test of the stable formula runs at tag
time in `release.yml`, after the release metadata gate has passed.

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 License.
