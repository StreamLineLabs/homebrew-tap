#!/usr/bin/env bash
set -euo pipefail

# update-formula.sh — Update the Homebrew formula with SHA256 hashes from a GitHub release.
#
# Usage:
#   ./scripts/update-formula.sh <version>
#   ./scripts/update-formula.sh 0.2.0
#   ./scripts/update-formula.sh 0.3.0 --create-pr
#
# Options:
#   --create-pr    Create a git branch and open a PR via gh CLI after updating
#   --dry-run      Show what would be changed without modifying the formula
#
# This script downloads the release tarballs, computes SHA256 hashes,
# and updates streamline.rb with real values.

VERSION="${1:?Usage: $0 <version> [--create-pr] [--dry-run]}"
shift
CREATE_PR=false
DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --create-pr) CREATE_PR=true ;;
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  esac
done

REPO="streamlinelabs/streamline"
FORMULA="${STREAMLINE_FORMULA:-streamline.rb}"
BASE_URL="${STREAMLINE_RELEASE_BASE_URL:-https://github.com/${REPO}/releases/download/v${VERSION}}"

TARGETS=(
  "aarch64-apple-darwin"
  "x86_64-apple-darwin"
  "aarch64-unknown-linux-gnu"
  "x86_64-unknown-linux-gnu"
)

PLACEHOLDER_KEYS=(
  "PLACEHOLDER_SHA256_ARM64_DARWIN"
  "PLACEHOLDER_SHA256_X64_DARWIN"
  "PLACEHOLDER_SHA256_ARM64_LINUX"
  "PLACEHOLDER_SHA256_X64_LINUX"
)

# Verify formula file exists
if [ ! -f "${FORMULA}" ]; then
  echo "❌ Formula file '${FORMULA}' not found. Run from the repository root."
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> Updating formula for Streamline v${VERSION}"

if [ "$DRY_RUN" = true ]; then
  echo "   (dry-run mode — no files will be modified)"
fi

FAILED_TARGETS=()
HASHES=()
for i in "${!TARGETS[@]}"; do
  target="${TARGETS[$i]}"
  tarball="streamline-${VERSION}-${target}.tar.gz"
  url="${BASE_URL}/${tarball}"

  echo "  Downloading ${tarball}..."
  if ! curl -fsSL -o "${TMPDIR}/${tarball}" "${url}"; then
    echo "  ❌ Failed to download ${url}"
    echo "     Skipping — release artifact may not exist yet."
    FAILED_TARGETS+=("${target}")
    continue
  fi

  sha256=$(shasum -a 256 "${TMPDIR}/${tarball}" | awk '{print $1}')

  # Reject empty-file hash (SHA256 of zero bytes)
  EMPTY_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  if [ "${sha256}" = "${EMPTY_HASH}" ]; then
    echo "  ❌ ${target}: Downloaded file is empty (0 bytes). Skipping."
    FAILED_TARGETS+=("${target}")
    continue
  fi

  echo "  ✅ ${target}: ${sha256}"
  HASHES[i]="${sha256}"
done

if [ "${#FAILED_TARGETS[@]}" -gt 0 ]; then
  echo "==> Missing artifacts for: ${FAILED_TARGETS[*]}"
  echo "    Formula was not modified."
  exit 1
fi

if [ "$DRY_RUN" = true ]; then
  echo "==> Dry run complete. No changes written."
  exit 0
fi

# Replace every checksum only after all release artifacts have validated.
for i in "${!TARGETS[@]}"; do
  target="${TARGETS[$i]}"
  placeholder="${PLACEHOLDER_KEYS[$i]}"
  sha256="${HASHES[$i]}"
  if grep -q "${placeholder}" "${FORMULA}"; then
    sed -i.bak "s/${placeholder}/${sha256}/" "${FORMULA}"
  else
    sed -i.bak "/${target}/{ n; s/sha256 \"[a-f0-9]\{64\}\"/sha256 \"${sha256}\"/; }" "${FORMULA}"
  fi
done

# Update versioned release URLs if they changed
CURRENT_VERSION=$(grep -Eo 'releases/download/v[0-9]+\.[0-9]+\.[0-9]+' "${FORMULA}" |
  head -1 | sed 's#releases/download/v##')
if [ "${CURRENT_VERSION}" != "${VERSION}" ]; then
  sed -i.bak \
    -e "s#/v${CURRENT_VERSION}/#/v${VERSION}/#g" \
    -e "s/streamline-${CURRENT_VERSION}-/streamline-${VERSION}-/g" \
    "${FORMULA}"
  echo "  📦 Version updated: ${CURRENT_VERSION} → ${VERSION}"
fi

rm -f "${FORMULA}.bak"

# Final validation: ensure no placeholder or empty-string hashes remain
EMPTY_HASH="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
if grep -q 'sha256 "PLACEHOLDER_SHA256' "${FORMULA}"; then
  echo "⚠️  Warning: Formula still contains placeholder hashes. Some artifacts may not have been available."
  echo "   Re-run this script once all release artifacts are published."
  exit 1
fi
if grep -q "${EMPTY_HASH}" "${FORMULA}"; then
  echo "⚠️  Warning: Formula still contains empty-file hashes. Release artifacts may be corrupt."
  exit 1
fi

echo "==> Formula updated successfully!"
echo "    Run 'brew audit --formula ${FORMULA}' to verify."

# Optionally create a PR
if [ "$CREATE_PR" = true ]; then
  if ! command -v gh &>/dev/null; then
    echo "❌ GitHub CLI (gh) is required for --create-pr. Install with: brew install gh"
    exit 1
  fi

  BRANCH="update/v${VERSION}"
  echo "==> Creating PR for v${VERSION}..."

  git checkout -b "${BRANCH}" 2>/dev/null || git switch "${BRANCH}"
  git add "${FORMULA}"
  git commit -m "chore: update formula to v${VERSION}

Update SHA256 hashes from release artifacts.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"

  git push -u origin "${BRANCH}"
  gh pr create \
    --title "Update Streamline to v${VERSION}" \
    --body "Automated formula update for Streamline v${VERSION}.

- Updated SHA256 hashes from release artifacts
- Updated version string

Triggered by: \`./scripts/update-formula.sh ${VERSION} --create-pr\`" \
    --label "automated"

  echo "==> PR created successfully!"
fi
