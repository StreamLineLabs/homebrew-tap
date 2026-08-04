#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

VERSION="9.9.9"
FORMULA="${TMPDIR}/streamline.rb"
RELEASE_DIR="${TMPDIR}/release"
cp "${ROOT}/streamline.rb" "${FORMULA}"
mkdir -p "${RELEASE_DIR}" "${TMPDIR}/payload"
printf '#!/bin/sh\nexit 0\n' >"${TMPDIR}/payload/streamline"
chmod +x "${TMPDIR}/payload/streamline"

targets=(
  "aarch64-apple-darwin"
  "x86_64-apple-darwin"
  "aarch64-unknown-linux-gnu"
  "x86_64-unknown-linux-gnu"
)

for target in "${targets[@]}"; do
  tar -czf "${RELEASE_DIR}/streamline-${VERSION}-${target}.tar.gz" \
    -C "${TMPDIR}/payload" streamline
done

STREAMLINE_FORMULA="${FORMULA}" \
STREAMLINE_RELEASE_BASE_URL="file://${RELEASE_DIR}" \
  "${ROOT}/scripts/update-formula.sh" "${VERSION}"

grep -q "releases/download/v${VERSION}" "${FORMULA}"
if grep -q 'sha256 "PLACEHOLDER_SHA256' "${FORMULA}"; then
  echo "Updater left placeholder hashes in the formula" >&2
  exit 1
fi

ruby -c "${FORMULA}" >/dev/null

MISSING_VERSION="10.0.0"
MISSING_FORMULA="${TMPDIR}/missing.rb"
BEFORE_MISSING="${TMPDIR}/missing-before.rb"
cp "${FORMULA}" "${MISSING_FORMULA}"
cp "${MISSING_FORMULA}" "${BEFORE_MISSING}"
for target in "${targets[@]:0:3}"; do
  tar -czf "${RELEASE_DIR}/streamline-${MISSING_VERSION}-${target}.tar.gz" \
    -C "${TMPDIR}/payload" streamline
done

if STREAMLINE_FORMULA="${MISSING_FORMULA}" \
  STREAMLINE_RELEASE_BASE_URL="file://${RELEASE_DIR}" \
  "${ROOT}/scripts/update-formula.sh" "${MISSING_VERSION}"; then
  echo "Updater unexpectedly accepted a release with a missing artifact" >&2
  exit 1
fi
cmp "${BEFORE_MISSING}" "${MISSING_FORMULA}"

echo "Formula updater fixture test passed"
