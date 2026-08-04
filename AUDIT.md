# Clean Code and SRP Audit

## Summary

- **Highest-leverage split:** separate release artifact/checksum updates from optional Git/GitHub pull-request publication in `scripts/update-formula.sh`.
- The formula itself is long but coherent: Homebrew installation, service definition, caveats, and tests change together under the packaging actor.
- Baseline validation is now hermetic for structure and updater behavior; stable installation remains correctly blocked until all four release artifacts exist.
- Updater mutation is atomic with respect to missing artifacts and is covered by success and partial-release fixtures.
- No extraction is implemented because the remaining split requires credentialed Git/GitHub behavior that cannot be characterized locally.

## Findings

| ID | Location | Category | Severity | Actors in conflict | Cost | Size | Behavior risk |
|---|---|---|---|---|---|---|---|
| BREW-SRP-1 | `scripts/update-formula.sh:1-180+` | SRP | P2 | Release artifact publisher vs. Git/GitHub pull-request workflow | Downloading artifacts, validating checksums, editing formula URLs, committing, pushing, and opening PRs change for unrelated systems. The update core needs curl/hash/formula state; PR publication needs git/gh credentials and repository policy. Split into `update-formula.sh` and `publish-formula-pr.sh` after credentialed characterization. | M | Medium |
| BREW-CC-1 | `streamline.rb` stable blocks | External dependency | P1 | Core release publisher | Placeholder checksums intentionally make stable install unavailable. Publishing one platform late must not produce a partially updated formula; the updater now prevents that, but real install/test remains blocked on all four artifacts. | S | High |
| BREW-CC-2 | `.github/workflows/update-formula.yml` | Cross-repo trigger | P2 | Core release automation and tap maintainers | Repository dispatch payload shape and timing are controlled outside this repo. A release event before assets are downloadable fails safely but requires replay. | S | Medium |
| BREW-CC-3 | `streamline.rb` test block | Mixed abstraction | P2 | Package validation | Binary existence, CLI contracts, HTTP readiness, management routes, and Kafka TCP readiness share one test. They serve the single installation contract, so splitting is not justified until failures need independent retries or diagnostics. | M | Low |
| BREW-SUP-1 | README and formula caveats | Path portability | P2 | macOS Intel, Apple Silicon, and Linux users | Documentation must use `brew --prefix`/formula `var` rather than architecture-specific `/usr/local` assumptions. The baseline now centralizes those portable paths. | S | Low |

## Ordered Refactor Sequence

1. Publish all four core v0.3.0 archives and run the updater fixture against the real release.
2. Run stable install/test on macOS ARM64, macOS Intel, Linux ARM64, and Linux x86_64.
3. Add a credentialed test repository for `--create-pr`.
4. Move Git branch/commit/push/PR behavior into `publish-formula-pr.sh`, leaving checksum mutation independently reusable.
5. Keep formula install/service/test behavior together unless platform-specific failures demonstrate separate reasons to change.

## Deferred

- **BREW-SRP-1:** GitHub PR publication cannot be verified without a disposable remote and credentials; moving it now would only relocate untested behavior.
- Stable formula installation and `brew test` are deferred until v0.3.0 artifacts and checksums exist.
- Signing, notarization, provenance, and retention of release archives require the org release policy in `MANUAL_TO_RUN.md`.

## Out of Scope

- Formula name, tap path, release asset names, installed binaries, service arguments, and CLI behavior remain public packaging contracts.
- No shared release helper is extracted across the tap and core repository.
- The Homebrew formula remains one class because its methods collectively describe one package and share Homebrew DSL state.
