#!/usr/bin/env bash
set -euo pipefail

# validate-formula.sh — Validate the formula in this working tree the way
# Homebrew actually consumes it: as a formula inside a tap.
#
# Usage:
#   ./scripts/validate-formula.sh [--mode pre-artifact|release]
#                                 [--install-head [--with-moonshot] | --install-stable]
#
# Options:
#   --mode            Stable-metadata mode to enforce (default: pre-artifact)
#   --install-head    After auditing, `brew install --HEAD` + `brew test`
#   --with-moonshot   With --install-head, exercise the formula's public
#                     `--with-moonshot` option, so the conditional Cargo
#                     `--features moonshot` build path is covered end to end
#   --install-stable  After auditing, `brew install` + `brew test` (fetches the
#                     published release archives; requires --mode release)
#
# Why a tap and not a file path:
#   `brew audit`/`brew install` against a bare path run in a degraded mode —
#   several audits (tap/formula-name agreement, `head`/`stable` spec resolution,
#   deprecation and disable handling) only apply to a tapped formula, and path
#   installs bypass the tap resolution users actually go through. Homebrew now
#   refuses a bare path outright ("Homebrew requires formulae to be in a tap"),
#   so a throwaway tap is the only way to run these checks at all.
#
# Why a copy and not a symlink:
#   Homebrew resolves the formula path through `realpath` before deciding
#   whether it lives in a tap. A symlink from the tap into this working tree
#   therefore resolves back to the repository checkout and is rejected exactly
#   like a bare path. The tap must hold a real file. The obvious risk of a copy
#   — auditing something that is no longer what is checked in — is closed by
#   comparing the copy against the repository formula with `cmp` twice: once
#   immediately after copying (the copy is faithful before anything reads it)
#   and once after every brew step has run (nothing, neither an editor in
#   another window nor a `--fix`-style rewrite by brew itself, changed either
#   side while the checks were passing). A green run therefore means the exact
#   bytes in this working tree passed. The tap is removed on exit, including on
#   failure.
#
# Offline by design for audits: `--online` audits are never requested, so no
# release artifact is fetched unless an explicit --install-* flag is passed.

MODE="pre-artifact"
DO_INSTALL="none"
WITH_MOONSHOT=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      MODE="${2:?--mode requires a value}"
      shift 2
      ;;
    --mode=*)
      MODE="${1#--mode=}"
      shift
      ;;
    --install-head)
      DO_INSTALL="head"
      shift
      ;;
    --install-stable)
      DO_INSTALL="stable"
      shift
      ;;
    --with-moonshot)
      WITH_MOONSHOT=true
      shift
      ;;
    -h | --help)
      sed -n '4,44p' "$0"
      exit 0
      ;;
    *)
      echo "❌ Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

case "${MODE}" in
  pre-artifact | release) ;;
  *)
    echo "❌ Unknown mode '${MODE}' (expected 'pre-artifact' or 'release')" >&2
    exit 2
    ;;
esac

if [ "${WITH_MOONSHOT}" = true ] && [ "${DO_INSTALL}" != "head" ]; then
  echo "❌ --with-moonshot only applies to --install-head: it is a source-build" >&2
  echo "   option, and bottle/stable installs never compile Cargo features." >&2
  exit 2
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "${SCRIPT_DIR}/.." && pwd)
FORMULA_NAME="streamline"
FORMULA_PATH="${ROOT}/${FORMULA_NAME}.rb"

if [ ! -f "${FORMULA_PATH}" ]; then
  echo "❌ '${FORMULA_PATH}' not found." >&2
  exit 2
fi

echo "==> Ruby syntax"
ruby -c "${FORMULA_PATH}" >/dev/null
echo "   ✅ ${FORMULA_PATH} parses"

echo "==> Stable release metadata"
"${SCRIPT_DIR}/check-formula-metadata.sh" --mode "${MODE}" "${FORMULA_PATH}"

if ! command -v brew >/dev/null 2>&1; then
  echo "⚠️  Homebrew is not installed; skipping 'brew style' and 'brew audit'." >&2
  echo "    Syntax and metadata checks above still ran." >&2
  if [ "${DO_INSTALL}" != "none" ]; then
    echo "❌ --install-${DO_INSTALL} was requested but Homebrew is unavailable." >&2
    exit 1
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Ephemeral tap. Named distinctly from the real tap so a developer machine that
# has `streamlinelabs/tap` installed is never touched, and refused outright if
# something already occupies the path.
# ---------------------------------------------------------------------------
TAP_USER="streamlinelabs-validate"
TAP_REPO="local"
TAP_NAME="${TAP_USER}/${TAP_REPO}"
FORMULA_REF="${TAP_NAME}/${FORMULA_NAME}"

BREW_REPOSITORY=$(brew --repository)
TAP_DIR="${BREW_REPOSITORY}/Library/Taps/${TAP_USER}/homebrew-${TAP_REPO}"

if [ -e "${TAP_DIR}" ]; then
  echo "❌ Ephemeral tap path already exists: ${TAP_DIR}" >&2
  echo "   A previous run may have been killed. Remove it with:" >&2
  echo "     brew untap ${TAP_NAME} || rm -rf '${TAP_DIR}'" >&2
  exit 1
fi

cleanup_tap() {
  local status=$?
  if [ "${DO_INSTALL}" != "none" ]; then
    brew uninstall --force "${FORMULA_REF}" >/dev/null 2>&1 || true
  fi
  # Only ever remove the exact directory this script created.
  case "${TAP_DIR}" in
    "${BREW_REPOSITORY}/Library/Taps/${TAP_USER}/homebrew-${TAP_REPO}")
      brew untap "${TAP_NAME}" >/dev/null 2>&1 || true
      rm -rf "${TAP_DIR}"
      rmdir "${BREW_REPOSITORY}/Library/Taps/${TAP_USER}" 2>/dev/null || true
      ;;
  esac
  return "${status}"
}
trap cleanup_tap EXIT

echo "==> Creating ephemeral tap ${TAP_NAME}"
if ! brew tap-new --no-git "${TAP_NAME}" >/dev/null 2>&1; then
  # `brew tap-new` is a convenience; a tap is just a directory layout.
  mkdir -p "${TAP_DIR}/Formula"
fi
mkdir -p "${TAP_DIR}/Formula"
# Drop anything tap-new scaffolded so only our formula is audited.
find "${TAP_DIR}/Formula" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
rm -rf "${TAP_DIR}/.github"

TAP_FORMULA="${TAP_DIR}/Formula/${FORMULA_NAME}.rb"

# A real file, not a symlink: Homebrew realpath-resolves the formula and would
# reject a link that points back out of the tap. `cp -p` keeps mode/timestamps
# so nothing but the location differs.
cp -p "${FORMULA_PATH}" "${TAP_FORMULA}"

# Guards against auditing a stale or diverged copy. Called immediately after
# the copy and again after every brew step; either direction of drift (the
# working tree edited mid-run, or brew rewriting the tapped file) fails the
# run instead of reporting a green result for bytes nobody validated.
assert_copy_matches() {
  local phase="$1"
  if [ ! -f "${TAP_FORMULA}" ]; then
    echo "❌ Tapped formula disappeared ${phase}: ${TAP_FORMULA}" >&2
    exit 1
  fi
  if ! cmp -s "${FORMULA_PATH}" "${TAP_FORMULA}"; then
    echo "❌ Tapped formula differs from the repository formula ${phase}." >&2
    echo "   Repository: ${FORMULA_PATH}" >&2
    echo "   Tapped:     ${TAP_FORMULA}" >&2
    echo "   The validation result would describe bytes that are not what is" >&2
    echo "   checked in, so it is discarded. Diff:" >&2
    diff -u "${FORMULA_PATH}" "${TAP_FORMULA}" 2>&1 | sed 's/^/   /' >&2 || true
    exit 1
  fi
}

assert_copy_matches "before validation"
echo "   ✅ ${TAP_FORMULA} is a byte-for-byte copy of ${FORMULA_PATH}"

echo "==> brew style"
brew style "${FORMULA_REF}"
assert_copy_matches "after brew style"

echo "==> brew audit (offline)"
brew audit --strict --formula "${FORMULA_REF}"
assert_copy_matches "after brew audit"
echo "   ✅ Audited formula still matches ${FORMULA_PATH} byte for byte"

case "${DO_INSTALL}" in
  none)
    echo
    echo "==> Audits passed. Install/test is a separate, artifact-dependent step:"
    echo "    ./scripts/validate-formula.sh --mode release --install-stable"
    echo "    ./scripts/validate-formula.sh --install-head"
    echo "    ./scripts/validate-formula.sh --install-head --with-moonshot"
    echo "    (all install paths are blocked while the formula carries its"
    echo "     fail-closed 'disable!' stanza — that is the intended state until"
    echo "     the release archives and their signed manifest are published)"
    ;;
  head)
    # The formula's public source-build option is passed through verbatim, so
    # `--with-moonshot` is exercised exactly as a user would type it and the
    # conditional `--features moonshot` cargo path is really compiled.
    HEAD_ARGS=(--HEAD)
    if [ "${WITH_MOONSHOT}" = true ]; then
      HEAD_ARGS+=(--with-moonshot)
    fi
    echo "==> brew install ${HEAD_ARGS[*]} ${FORMULA_REF}"
    brew install "${HEAD_ARGS[@]}" "${FORMULA_REF}"
    echo "==> brew test ${FORMULA_REF}"
    brew test "${FORMULA_REF}"
    assert_copy_matches "after HEAD install and test"
    echo "==> HEAD install and test passed!"
    ;;
  stable)
    if [ "${MODE}" != "release" ]; then
      echo "❌ --install-stable requires --mode release so the stable metadata gate" >&2
      echo "   has actually verified that artifact URLs and checksums exist." >&2
      exit 2
    fi
    echo "==> brew install ${FORMULA_REF}"
    brew install "${FORMULA_REF}"
    echo "==> brew test ${FORMULA_REF}"
    brew test "${FORMULA_REF}"
    assert_copy_matches "after stable install and test"
    echo "==> Stable install and test passed!"
    ;;
esac
