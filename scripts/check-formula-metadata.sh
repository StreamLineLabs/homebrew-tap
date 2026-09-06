#!/usr/bin/env bash
set -euo pipefail

# check-formula-metadata.sh — deterministic, offline validation of the stable
# release metadata recorded in the Homebrew formula.
#
# Usage:
#   ./scripts/check-formula-metadata.sh [--mode pre-artifact|release] [formula]
#
# Modes:
#   pre-artifact (default)
#       Accepts exactly two states and nothing in between:
#         (a) BLOCKED   — no stable artifact metadata at all, and the generated
#                         region carries exactly one `disable!` blocker so that
#                         *every* install path (stable and --HEAD) fails closed.
#                         The blocker's `date:` must be a real calendar date no
#                         later than today (UTC): Homebrew treats a future
#                         disable! date as a mere deprecation, so a blocker
#                         dated ahead of today does not fail closed and is
#                         refused. Nothing is fabricated, nothing falls back.
#         (b) RELEASE   — a complete, well-formed stable stanza: four artifact
#                         URLs that all encode the same version and four real
#                         SHA256 hashes, and no `disable!` blocker anywhere.
#       Any placeholder, "pending"/"TBD" marker, `sha256 :no_check`, malformed
#       checksum, partially generated stanza, missing blocker, or stable
#       metadata written outside the generated region is a hard failure.
#
#   release
#       Requires state (b). A blocked formula is a hard failure, so the release
#       gate stays red until real URLs and hashes are supplied.
#
# On the version: the formula deliberately carries no `version` stanza. Homebrew
# infers the version from the artifact URL, and the only place the generator
# could write a stanza is after `head do`, where `brew style`'s
# FormulaAudit/ComponentsOrder cop rejects it (`version` must precede
# `license`). The release version is therefore derived here from the four
# artifact URLs, which must all agree, and an explicit `version` stanza anywhere
# in the formula is refused.
#
# This check never performs network I/O and never invokes Homebrew.

MODE="pre-artifact"
FORMULA="${STREAMLINE_FORMULA:-streamline.rb}"

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
    -h | --help)
      sed -n '3,40p' "$0"
      exit 0
      ;;
    -*)
      echo "❌ Unknown option: $1" >&2
      exit 2
      ;;
    *)
      FORMULA="$1"
      shift
      ;;
  esac
done

case "$MODE" in
  pre-artifact | release) ;;
  *)
    echo "❌ Unknown mode '${MODE}' (expected 'pre-artifact' or 'release')" >&2
    exit 2
    ;;
esac

if [ ! -f "${FORMULA}" ]; then
  echo "❌ Formula file '${FORMULA}' not found. Run from the repository root." >&2
  exit 2
fi

EXPECTED_TARGETS=(
  "aarch64-apple-darwin"
  "x86_64-apple-darwin"
  "aarch64-unknown-linux-gnu"
  "x86_64-unknown-linux-gnu"
)

FAILURES=()
fail() { FAILURES+=("$1"); }

# Pure-shell proleptic-Gregorian calendar validation. `date -d` is GNU-only and
# `date -j -f` is BSD-only, so neither is portable across the macOS and Linux
# runners this gate executes on; the arithmetic below is.
is_real_calendar_date() {
  local y m d dim
  y=$((10#${1:0:4}))
  m=$((10#${1:5:2}))
  d=$((10#${1:8:2}))
  [ "${y}" -ge 1 ] || return 1
  [ "${m}" -ge 1 ] && [ "${m}" -le 12 ] || return 1
  [ "${d}" -ge 1 ] || return 1
  case "${m}" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) dim=31 ;;
    4 | 6 | 9 | 11) dim=30 ;;
    2)
      if [ $((y % 4)) -eq 0 ] && { [ $((y % 100)) -ne 0 ] || [ $((y % 400)) -eq 0 ]; }; then
        dim=29
      else
        dim=28
      fi
      ;;
    *) return 1 ;;
  esac
  [ "${d}" -le "${dim}" ]
}

# YYYY-MM-DD -> YYYYMMDD as a base-10 integer. `10#` is required: `08`/`09`
# would otherwise be read as invalid octal in an arithmetic context.
date_as_int() {
  printf '%d' "$((10#${1:0:4} * 10000 + 10#${1:5:2} * 100 + 10#${1:8:2}))"
}

echo "==> Checking stable metadata in '${FORMULA}' (mode: ${MODE})"

# ---------------------------------------------------------------------------
# 1. Untrusted / unverifiable checksum markers are never acceptable.
# ---------------------------------------------------------------------------
if grep -Eqi '^[[:space:]]*sha256[[:space:]]+"?(PLACEHOLDER|PENDING|TBD|TODO|CHANGEME|XXX)' "${FORMULA}"; then
  fail "formula contains a placeholder/pending SHA256 value"
fi

if grep -Eq '^[[:space:]]*sha256[[:space:]]+:no_check' "${FORMULA}"; then
  fail "formula uses 'sha256 :no_check', which disables archive authentication"
fi

if grep -Eq '^[[:space:]]*sha256[[:space:]]+"' "${FORMULA}"; then
  while IFS= read -r value; do
    if ! printf '%s' "${value}" | grep -Eq '^[a-f0-9]{64}$'; then
      fail "malformed SHA256 literal: '${value}' (expected 64 lowercase hex chars)"
    fi
    if [ "${value}" = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ]; then
      fail "SHA256 of an empty (0-byte) archive is recorded"
    fi
    if printf '%s' "${value}" | grep -Eq '^(a{64}|0{64}|f{64})$'; then
      fail "SHA256 '${value}' is a synthetic filler value, not a real digest"
    fi
  done < <(grep -Eo '^[[:space:]]*sha256[[:space:]]+"[^"]*"' "${FORMULA}" |
    sed -E 's/^[[:space:]]*sha256[[:space:]]+"//; s/"$//')
fi

# ---------------------------------------------------------------------------
# 2. Determine whether stable artifact metadata is present at all.
# ---------------------------------------------------------------------------
BEGIN_MARKER='# >>> STABLE ARTIFACTS BEGIN'
END_MARKER='# >>> STABLE ARTIFACTS END'
begin_count=$(grep -cF "${BEGIN_MARKER}" "${FORMULA}" || true)
end_count=$(grep -cF "${END_MARKER}" "${FORMULA}" || true)
if [ "${begin_count}" != "1" ] || [ "${end_count}" != "1" ]; then
  echo "❌ Stable metadata check failed:"
  echo "   - expected exactly one generated stable-artifacts region (found ${begin_count} begin / ${end_count} end markers)"
  exit 1
fi

# The generated region is the only place stable artifact metadata and the
# fail-closed blocker may live, so state is derived from the region and then
# cross-checked against the whole file.
REGION_FILE=$(mktemp)
trap 'rm -f "${REGION_FILE}"' EXIT
awk -v b="${BEGIN_MARKER}" -v e="${END_MARKER}" '
  index($0, b) { inside = 1; next }
  index($0, e) { inside = 0; next }
  inside
' "${FORMULA}" >"${REGION_FILE}"

URL_RE='^[[:space:]]*url[[:space:]]+"[^"]+\.tar\.gz"'
SHA_RE='^[[:space:]]*sha256[[:space:]]+'
VERSION_RE='^[[:space:]]*version[[:space:]]+"[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?"[[:space:]]*$'
DISABLE_RE='^[[:space:]]*disable![[:space:]]'

count_matches() { grep -Ec "$1" "$2" || true; }

RELEASE_URL_COUNT=$(count_matches "${URL_RE}" "${REGION_FILE}")
SHA_COUNT=$(count_matches "${SHA_RE}" "${REGION_FILE}")
DISABLE_COUNT=$(count_matches "${DISABLE_RE}" "${REGION_FILE}")

FILE_URL_COUNT=$(count_matches "${URL_RE}" "${FORMULA}")
FILE_SHA_COUNT=$(count_matches "${SHA_RE}" "${FORMULA}")
FILE_VERSION_COUNT=$(count_matches "${VERSION_RE}" "${FORMULA}")
FILE_DISABLE_COUNT=$(count_matches "${DISABLE_RE}" "${FORMULA}")

if [ "${FILE_URL_COUNT}" != "${RELEASE_URL_COUNT}" ] ||
  [ "${FILE_SHA_COUNT}" != "${SHA_COUNT}" ]; then
  fail "stable artifact metadata (url/sha256) exists outside the generated region; only scripts/update-formula.sh may record it, inside the markers"
fi
if [ "${FILE_DISABLE_COUNT}" != "${DISABLE_COUNT}" ]; then
  fail "a 'disable!' stanza exists outside the generated region; the fail-closed blocker must live inside the markers so the updater can replace it"
fi

# The version is inferred by Homebrew from the artifact URLs. An explicit
# stanza is redundant, and the only position the generator could write one is
# after `head do`, where `brew style` (FormulaAudit/ComponentsOrder) rejects it
# because `version` must precede `license`. So it is refused outright rather
# than tolerated in a position that fails Homebrew review.
if [ "${FILE_VERSION_COUNT}" -ne 0 ]; then
  fail "explicit 'version' stanza found (${FILE_VERSION_COUNT}); the version is inferred from the artifact URLs, and a stanza in the generated region violates Homebrew's component order (version must precede license)"
fi

STATE="partial"
if [ "${RELEASE_URL_COUNT}" -eq 0 ] && [ "${SHA_COUNT}" -eq 0 ]; then
  STATE="blocked"
elif [ "${RELEASE_URL_COUNT}" -eq 4 ] && [ "${SHA_COUNT}" -eq 4 ]; then
  STATE="release"
fi

if [ "${STATE}" = "partial" ]; then
  fail "stable metadata is partially generated (${RELEASE_URL_COUNT}/4 release URLs, ${SHA_COUNT}/4 checksums); it must be either fully absent or fully populated"
fi

# ---------------------------------------------------------------------------
# 3. State-specific checks.
# ---------------------------------------------------------------------------
if [ "${STATE}" = "blocked" ]; then
  # Without a stable spec, Homebrew would fall back to the head-only spec and
  # an unqualified `brew install streamline` would quietly build from git. The
  # blocker makes that impossible: the formula refuses every install path.
  if [ "${DISABLE_COUNT}" -ne 1 ]; then
    fail "blocked formula must carry exactly one 'disable!' blocker inside the generated region (found ${DISABLE_COUNT}); without it an unqualified install silently falls back to HEAD"
  else
    disable_line=$(grep -E -m1 "${DISABLE_RE}" "${REGION_FILE}")

    # -------------------------------------------------------------------
    # The blocker's date is load-bearing, not decorative.
    #
    # Homebrew treats `disable!` with a date in the *future* as a
    # deprecation: the formula keeps installing (with a warning) until that
    # day arrives. So a blocked formula carrying a future date does not fail
    # closed at all — `brew install streamline` would fall back to the
    # head-only spec and quietly build from git, which is precisely the
    # outcome the blocked state exists to prevent. A future date is
    # therefore a hard failure and is never reported as a valid BLOCKED
    # state; so is a malformed or impossible one (2026-02-30, 2026-13-01),
    # which Homebrew would reject outright when loading the formula.
    # -------------------------------------------------------------------
    date_matches=$(grep -Eo 'date:[[:space:]]*"[^"]*"' <<<"${disable_line}" || true)
    date_count=$(grep -c . <<<"${date_matches}" || true)
    disable_date=$(sed -E 's/^date:[[:space:]]*"//; s/"$//' <<<"${date_matches%%$'\n'*}")

    if [ "${date_count}" -ne 1 ]; then
      fail "'disable!' blocker must carry exactly one date: \"YYYY-MM-DD\" argument (found ${date_count} in: ${disable_line})"
    elif ! grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' <<<"${disable_date}"; then
      fail "'disable!' blocker date must be a literal \"YYYY-MM-DD\" string, found '${disable_date}' (in: ${disable_line})"
    elif ! is_real_calendar_date "${disable_date}"; then
      fail "'disable!' blocker date '${disable_date}' is not a real calendar date; Homebrew cannot parse it, so the formula would not load at all"
    else
      TODAY_UTC=$(date -u +%Y-%m-%d)
      if [ "$(date_as_int "${disable_date}")" -gt "$(date_as_int "${TODAY_UTC}")" ]; then
        fail "'disable!' blocker date '${disable_date}' is in the future (today, UTC: ${TODAY_UTC}); Homebrew treats a future disable! date as a deprecation, so installs would still succeed with a warning and 'brew install streamline' would silently fall back to a HEAD build — this state is NOT fail-closed"
      fi
    fi

    if ! grep -Eq 'because:[[:space:]]*"[^"]+"' <<<"${disable_line}"; then
      fail "'disable!' blocker must carry an explicit because: \"...\" reason (found: ${disable_line})"
    fi
  fi
fi

if [ "${STATE}" = "release" ]; then
  # A verified stable stanza and a fail-closed blocker are mutually exclusive:
  # the updater replaces one with the other.
  if [ "${FILE_DISABLE_COUNT}" -ne 0 ]; then
    fail "stable artifacts are recorded but a 'disable!' blocker is still present; the updater must replace the blocker, not append to it"
  fi

  # Production artifacts must come from the upstream GitHub release. Local
  # fixture URLs are tolerated only for hermetic tests that opt in explicitly.
  if [ "${STREAMLINE_ALLOW_LOCAL_FIXTURES:-0}" != "1" ]; then
    while IFS= read -r artifact_url; do
      case "${artifact_url}" in
        https://github.com/streamlinelabs/streamline/releases/download/*) ;;
        *) fail "stable artifact URL is not an upstream GitHub release download: '${artifact_url}'" ;;
      esac
    done < <(grep -Eo '^[[:space:]]*url[[:space:]]+"[^"]+\.tar\.gz"' "${FORMULA}" |
      sed -E 's/^[[:space:]]*url[[:space:]]+"//; s/"$//')
  fi

  # ---------------------------------------------------------------------
  # The version is not stated anywhere in the formula: Homebrew derives it
  # from the artifact URL, so this gate derives it the same way. Each of the
  # four expected targets must contribute exactly one artifact name, and all
  # four names must encode the same version — that agreement is what makes
  # the inferred version trustworthy in the absence of a `version` stanza.
  # ---------------------------------------------------------------------
  asset_versions=""
  missing_targets=""
  for target in "${EXPECTED_TARGETS[@]}"; do
    found=$(grep -Eo "streamline-v[^\"/]+-${target}\.tar\.gz" "${FORMULA}" |
      sed -E "s/^streamline-v//; s/-${target}\.tar\.gz$//" | sort -u)
    if [ -z "${found}" ]; then
      missing_targets="${missing_targets} ${target}"
      continue
    fi
    if [ "$(printf '%s\n' "${found}" | grep -c .)" != "1" ]; then
      fail "artifact URLs for '${target}' reference more than one version: $(printf '%s' "${found}" | tr '\n' ' ')"
      continue
    fi
    asset_versions="${asset_versions}${found}
"
  done

  if [ -n "${missing_targets}" ]; then
    fail "missing or misnamed stable artifact URL(s) for:${missing_targets} (expected .../streamline-v<version>-<target>.tar.gz)"
  fi

  FORMULA_VERSION=""
  distinct_versions=$(printf '%s' "${asset_versions}" | sort -u | grep -c . || true)
  if [ "${distinct_versions}" != "1" ]; then
    fail "stable artifact names reference ${distinct_versions} version(s):$(printf '%s' "${asset_versions}" | sort -u | tr '\n' ' ' | sed 's/^/ /'); all four URLs must encode one version, since Homebrew infers the formula version from them"
  else
    FORMULA_VERSION=$(printf '%s' "${asset_versions}" | sort -u | head -1)
    if ! printf '%s' "${FORMULA_VERSION}" |
      grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)([-+][0-9A-Za-z.-]+)?$'; then
      fail "version inferred from the artifact URLs is not a semantic version: '${FORMULA_VERSION}'"
      FORMULA_VERSION=""
    fi
  fi

  # The release tag directory in each URL must agree with the inferred version
  # too, so a stale tag path cannot silently ship a different build.
  if [ -n "${FORMULA_VERSION}" ] && [ "${STREAMLINE_ALLOW_LOCAL_FIXTURES:-0}" != "1" ]; then
    while IFS= read -r artifact_url; do
      case "${artifact_url}" in
        */download/"v${FORMULA_VERSION}"/*) ;;
        *) fail "artifact URL release tag disagrees with the version inferred from the archive name '${FORMULA_VERSION}': '${artifact_url}'" ;;
      esac
    done < <(grep -Eo '^[[:space:]]*url[[:space:]]+"[^"]+\.tar\.gz"' "${FORMULA}" |
      sed -E 's/^[[:space:]]*url[[:space:]]+"//; s/"$//')
  fi

  unique_hashes=$(grep -Eo '^[[:space:]]*sha256[[:space:]]+"[a-f0-9]{64}"' "${FORMULA}" |
    sed -E 's/.*"([a-f0-9]{64})"/\1/' | sort -u | wc -l | tr -d ' ')
  if [ "${unique_hashes}" != "4" ]; then
    fail "expected 4 distinct artifact checksums, found ${unique_hashes} (duplicated hashes indicate a copy/paste error)"
  fi
fi

if [ "${MODE}" = "release" ] && [ "${STATE}" = "blocked" ]; then
  fail "release mode requires published stable artifact metadata, but the formula is blocked (disable! blocker, no stable spec); publish the release archives and run './scripts/update-formula.sh <version>'"
fi

# ---------------------------------------------------------------------------
# 4. Report.
# ---------------------------------------------------------------------------
if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "❌ Stable metadata check failed:"
  for failure in "${FAILURES[@]}"; do
    echo "   - ${failure}"
  done
  exit 1
fi

case "${STATE}" in
  blocked)
    echo "✅ State: BLOCKED. No fabricated checksums; 'disable!' fails every install path closed"
    echo "   (stable and --HEAD), so nothing falls back to an unverified build."
    echo "   Blocker date is a real calendar date that has already passed (UTC), so the"
    echo "   disablement is in force today rather than being a future-dated deprecation."
    echo "   Release gate will stay red until real artifact URLs and hashes are supplied."
    ;;
  release)
    echo "✅ State: RELEASE. 4 artifact URLs and 4 verified-format checksums present,"
    echo "   all four URLs agree on version ${FORMULA_VERSION:-unknown} (which Homebrew infers from them,"
    echo "   so no redundant 'version' stanza is carried), and the fail-closed blocker"
    echo "   has been replaced."
    ;;
esac
