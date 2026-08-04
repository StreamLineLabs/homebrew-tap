#!/usr/bin/env bash
set -euo pipefail

FORMULA="streamline.rb"
TAP="streamlinelabs/test"

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to audit ${FORMULA}" >&2
  exit 1
fi

brew tap-new "${TAP}" --no-git >/dev/null 2>&1 || true
tap_formula="$(brew --repository "${TAP}")/Formula/streamline.rb"
cp "${FORMULA}" "${tap_formula}"

# Placeholder hashes intentionally block installation until release artifacts
# exist. Substitute a syntactically valid hash only for structural auditing.
ruby -pi -e \
  'gsub(/PLACEHOLDER_SHA256_[A-Z0-9_]+/, "a" * 64)' \
  "${tap_formula}"

brew audit --strict --formula "${TAP}/streamline"
brew style "${TAP}/streamline"
