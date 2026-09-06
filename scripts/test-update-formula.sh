#!/usr/bin/env bash
set -euo pipefail

# test-update-formula.sh — hermetic tests for scripts/update-formula.sh and
# scripts/check-formula-metadata.sh.
#
# Everything runs against local `file://` fixture releases: no network access,
# no Homebrew, no real artifacts and no invented checksums (fixture hashes are
# computed from the fixture archives themselves).
#
# State independence: the updater cases run against a *pinned blocked fixture*
# derived from the checked-in formula, never against the checked-in formula's
# own mutable state. The baseline section reads the real formula's state once
# and asserts the invariants that hold for that state, so this suite stays
# green both before the release artifacts exist (blocked) and after
# scripts/update-formula.sh has written real stable metadata (release).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

UPDATER="${ROOT}/scripts/update-formula.sh"
METADATA_CHECK="${ROOT}/scripts/check-formula-metadata.sh"
LIVE_FORMULA="${ROOT}/streamline.rb"
CI_WORKFLOW="${ROOT}/.github/workflows/ci.yml"
PAYLOAD="${WORKDIR}/payload"
RELEASE_DIR="${WORKDIR}/release"
mkdir -p "${PAYLOAD}" "${RELEASE_DIR}"

BEGIN_MARKER='# >>> STABLE ARTIFACTS BEGIN'
END_MARKER='# >>> STABLE ARTIFACTS END'

TARGETS=(
  "aarch64-apple-darwin"
  "x86_64-apple-darwin"
  "aarch64-unknown-linux-gnu"
  "x86_64-unknown-linux-gnu"
)

FAILED=0
pass() { echo "  ✅ $1"; }
fail() {
  echo "  ❌ $1" >&2
  FAILED=1
}

printf '#!/bin/sh\nexit 0\n' >"${PAYLOAD}/streamline"
printf '#!/bin/sh\nexit 0\n' >"${PAYLOAD}/streamline-cli"
chmod +x "${PAYLOAD}/streamline" "${PAYLOAD}/streamline-cli"

# Distinct payloads per target so the four checksums are genuinely different.
make_release() {
  local version="$1"
  shift
  local targets=("$@")
  local manifest="${RELEASE_DIR}/checksums.txt"
  : >"${manifest}"
  for target in "${targets[@]}"; do
    local dir="${WORKDIR}/payload-${version}-${target}"
    mkdir -p "${dir}"
    cp "${PAYLOAD}/streamline" "${PAYLOAD}/streamline-cli" "${dir}/"
    printf 'target=%s version=%s\n' "${target}" "${version}" >"${dir}/BUILDINFO"
    local tarball="streamline-v${version}-${target}.tar.gz"
    tar -czf "${RELEASE_DIR}/${tarball}" -C "${dir}" streamline streamline-cli BUILDINFO
    (cd "${RELEASE_DIR}" && shasum -a 256 "${tarball}") >>"${manifest}"
  done
}

run_updater() {
  local formula="$1" version="$2"
  shift 2
  STREAMLINE_FORMULA="${formula}" \
    STREAMLINE_RELEASE_BASE_URL="file://${RELEASE_DIR}" \
    STREAMLINE_REQUIRE_SIGNATURE="${REQUIRE_SIG:-0}" \
    STREAMLINE_ALLOW_LOCAL_FIXTURES=1 \
    "${UPDATER}" "${version}" "$@"
}

# ---------------------------------------------------------------------------
# Pinned blocked fixture.
#
# The formula body is taken from the repository so the fixture never drifts
# from the real thing, but the generated region is forced to the canonical
# blocked content. That makes every updater case below independent of whether
# the checked-in formula currently records real release metadata.
# ---------------------------------------------------------------------------
BLOCKED_REGION_FILE="${WORKDIR}/blocked-region.rb"
cat >"${BLOCKED_REGION_FILE}" <<'EOF'
  # No verified stable release artifacts are recorded: every install path is
  # blocked until scripts/update-formula.sh replaces this region.
  disable! date: "2026-09-02", because: "no verified upstream release artifacts are published for this formula yet"
EOF

BLOCKED_FIXTURE="${WORKDIR}/blocked-fixture.rb"
awk -v b="${BEGIN_MARKER}" -v e="${END_MARKER}" -v body="${BLOCKED_REGION_FILE}" '
  index($0, b) {
    print
    while ((getline line < body) > 0) print line
    close(body)
    inside = 1
    next
  }
  index($0, e) { inside = 0; print; next }
  !inside      { print }
' "${LIVE_FORMULA}" >"${BLOCKED_FIXTURE}"

fresh_formula() {
  local dest="$1"
  cp "${BLOCKED_FIXTURE}" "${dest}"
}

assert_unchanged() {
  local label="$1" formula="$2" baseline="$3"
  if cmp -s "${baseline}" "${formula}"; then
    pass "${label}: formula left byte-for-byte unchanged"
  else
    fail "${label}: formula was mutated despite a failed verification"
  fi
}

region_of() {
  awk -v b="${BEGIN_MARKER}" -v e="${END_MARKER}" '
    index($0, b) { inside = 1; next }
    index($0, e) { inside = 0; next }
    inside
  ' "$1"
}

# ---------------------------------------------------------------------------
echo "==> Baseline: the checked-in formula is loadable and internally consistent"
ruby -c "${LIVE_FORMULA}" >/dev/null && pass "ruby -c streamline.rb"

if "${METADATA_CHECK}" --mode pre-artifact "${LIVE_FORMULA}" >/dev/null; then
  pass "pre-artifact metadata gate accepts the checked-in formula"
else
  fail "pre-artifact metadata gate rejects the checked-in formula"
fi

# The public source/HEAD build contract is asserted by executing the formula's
# real `install` method against a stub Homebrew DSL (no brew, no network).
if ruby "${ROOT}/scripts/test-formula-options.rb" "${LIVE_FORMULA}" >"${WORKDIR}/live-options.log" 2>&1; then
  pass "checked-in formula satisfies the --with-moonshot HEAD build contract"
else
  cat "${WORKDIR}/live-options.log" >&2
  fail "checked-in formula breaks the --with-moonshot HEAD build contract"
fi

# The checked-in formula is mutable: before the upstream release exists it is
# blocked, and after scripts/update-formula.sh runs it records real metadata.
# Assert the invariants of whichever state it is actually in, so this suite
# never has to be edited when that state legitimately changes.
if "${METADATA_CHECK}" --mode release "${LIVE_FORMULA}" >/dev/null 2>&1; then
  LIVE_STATE="release"
else
  LIVE_STATE="blocked"
fi
echo "    (detected state: ${LIVE_STATE})"

case "${LIVE_STATE}" in
  blocked)
    disable_count=$(region_of "${LIVE_FORMULA}" | grep -Ec '^[[:space:]]*disable![[:space:]]' || true)
    if [ "${disable_count}" -eq 1 ]; then
      pass "blocked state: generated region carries exactly one fail-closed disable! blocker"
    else
      fail "blocked state: expected exactly one disable! blocker in the generated region, found ${disable_count}"
    fi
    if grep -Eq '^[[:space:]]*version[[:space:]]+"' "${LIVE_FORMULA}"; then
      fail "blocked state: a version stanza is present but no stable artifacts are recorded"
    else
      pass "blocked state: no stable version stanza and no fabricated checksums"
    fi
    ;;
  release)
    if grep -Eq '^[[:space:]]*disable![[:space:]]' "${LIVE_FORMULA}"; then
      fail "release state: fail-closed disable! blocker was not removed by the updater"
    else
      pass "release state: blocker replaced by verified stable metadata"
    fi
    pass "release state: release metadata gate is green"
    ;;
esac

# The version is inferred from the artifact URLs in *both* states. An explicit
# `version` stanza is redundant and, in the only place the generator could put
# one (after `head do`), it fails `brew style`'s FormulaAudit/ComponentsOrder
# cop because `version` must precede `license`.
if grep -Eq '^[[:space:]]*version[[:space:]]+"' "${LIVE_FORMULA}"; then
  fail "checked-in formula carries an explicit version stanza; Homebrew infers the version from the artifact URLs and the stanza breaks component order"
else
  pass "checked-in formula carries no explicit version stanza (version is URL-inferred)"
fi

# ---------------------------------------------------------------------------
echo "==> Fixture: the pinned blocked fixture is well-formed"
ruby -c "${BLOCKED_FIXTURE}" >/dev/null && pass "pinned blocked fixture is valid Ruby"
"${METADATA_CHECK}" --mode pre-artifact "${BLOCKED_FIXTURE}" >/dev/null &&
  pass "pinned blocked fixture passes the pre-artifact gate" ||
  fail "pinned blocked fixture rejected by the pre-artifact gate"
if "${METADATA_CHECK}" --mode release "${BLOCKED_FIXTURE}" >/dev/null 2>&1; then
  fail "pinned blocked fixture must not satisfy the release gate"
else
  pass "pinned blocked fixture keeps the release gate red"
fi

# ---------------------------------------------------------------------------
echo "==> Case 0: a blocked formula without the disable! blocker is rejected"
NOBLOCK="${WORKDIR}/case0.rb"
grep -v '^[[:space:]]*disable![[:space:]]' "${BLOCKED_FIXTURE}" >"${NOBLOCK}"
if "${METADATA_CHECK}" --mode pre-artifact "${NOBLOCK}" >/dev/null 2>&1; then
  fail "case 0: metadata gate accepted a blocked formula that silently falls back to HEAD"
else
  pass "case 0: blocked formula without a disable! blocker hard-fails"
fi

MISPLACED="${WORKDIR}/case0b.rb"
awk -v e="${END_MARKER}" '
  index($0, e) { print; print "  disable! date: \"2026-09-02\", because: \"outside the generated region\""; next }
  { print }
' "${NOBLOCK}" >"${MISPLACED}"
if "${METADATA_CHECK}" --mode pre-artifact "${MISPLACED}" >/dev/null 2>&1; then
  fail "case 0: metadata gate accepted a disable! blocker outside the generated region"
else
  pass "case 0: disable! outside the generated region hard-fails"
fi

# ---------------------------------------------------------------------------
# The blocker's date decides whether the blocked state is actually closed.
# Homebrew treats `disable!` with a future date as a deprecation: the formula
# still installs, with a warning, until that day. A blocked formula dated ahead
# of today therefore lets `brew install streamline` fall back to the head-only
# spec and build from git — the exact outcome the blocker exists to prevent —
# so a future date must be refused rather than reported as fail-closed.
echo "==> Case 0c: the disable! blocker date must be real and already in force"

# Rewrites the blocker date in a fresh blocked fixture. `date:` is the only
# thing that changes; because:/placement/count all stay valid, so the gate's
# verdict isolates the date check.
blocked_with_date() {
  local dest="$1" new_date="$2"
  # awk, not sed: the fixture dates deliberately include malformed values such
  # as "2026/09/02", which would collide with sed's `/` delimiter.
  awk -v d="${new_date}" '
    { sub(/disable! date: "[^"]*"/, "disable! date: \"" d "\"") ; print }
  ' "${BLOCKED_FIXTURE}" >"${dest}"
}

TODAY_UTC=$(date -u +%Y-%m-%d)

# (a) Today (UTC) is in force as of this instant and must be accepted — this is
#     the state the checked-in formula is in.
TODAY_FIXTURE="${WORKDIR}/case0c-today.rb"
blocked_with_date "${TODAY_FIXTURE}" "${TODAY_UTC}"
if "${METADATA_CHECK}" --mode pre-artifact "${TODAY_FIXTURE}" >"${WORKDIR}/case0c-today.out" 2>&1; then
  pass "case 0c: a blocker dated today (UTC ${TODAY_UTC}) is accepted"
else
  cat "${WORKDIR}/case0c-today.out" >&2
  fail "case 0c: a blocker dated today (UTC ${TODAY_UTC}) was rejected"
fi

# (b) A past date is in force too.
PAST_FIXTURE="${WORKDIR}/case0c-past.rb"
blocked_with_date "${PAST_FIXTURE}" "2001-02-28"
if "${METADATA_CHECK}" --mode pre-artifact "${PAST_FIXTURE}" >/dev/null 2>&1; then
  pass "case 0c: a blocker dated in the past is accepted"
else
  fail "case 0c: a blocker dated in the past was rejected"
fi

# (c) The checked-in blocker itself must remain valid. This is the regression
#     that matters day to day: the date shipped in streamline.rb has to keep
#     passing until the release artifacts replace the whole region.
if "${METADATA_CHECK}" --mode pre-artifact "${BLOCKED_FIXTURE}" >/dev/null 2>&1; then
  pass "case 0c: the checked-in blocker date is still in force"
else
  fail "case 0c: the checked-in blocker date no longer passes the date gate"
fi

# (d) Future dates are not fail-closed and must be refused, near and far.
for future_date in "2999-12-31" "2100-01-01"; do
  FUTURE_FIXTURE="${WORKDIR}/case0c-future-${future_date}.rb"
  blocked_with_date "${FUTURE_FIXTURE}" "${future_date}"
  if "${METADATA_CHECK}" --mode pre-artifact "${FUTURE_FIXTURE}" >"${WORKDIR}/case0c-future.out" 2>&1; then
    fail "case 0c: metadata gate accepted a future-dated blocker (${future_date}); Homebrew would only deprecate, not disable, so installs still fall back to HEAD"
  elif grep -q "is in the future" "${WORKDIR}/case0c-future.out"; then
    pass "case 0c: future-dated blocker '${future_date}' hard-fails with a date-specific reason"
  else
    cat "${WORKDIR}/case0c-future.out" >&2
    fail "case 0c: future-dated blocker '${future_date}' failed, but not because of its date"
  fi
done

# Tomorrow, computed from today without GNU/BSD-specific `date` arithmetic: the
# same day number in the next year is always strictly in the future and always
# a real calendar date, since 02-29 cannot be produced from a valid today in a
# non-leap year... except when today *is* 02-29, so that case steps to 03-01.
if [ "${TODAY_UTC:5}" = "02-29" ]; then
  NEAR_FUTURE="$((10#${TODAY_UTC:0:4} + 1))-03-01"
else
  NEAR_FUTURE="$((10#${TODAY_UTC:0:4} + 1))${TODAY_UTC:4}"
fi
NEAR_FIXTURE="${WORKDIR}/case0c-near-future.rb"
blocked_with_date "${NEAR_FIXTURE}" "${NEAR_FUTURE}"
if "${METADATA_CHECK}" --mode pre-artifact "${NEAR_FIXTURE}" >/dev/null 2>&1; then
  fail "case 0c: metadata gate accepted a blocker dated one year out (${NEAR_FUTURE})"
else
  pass "case 0c: a blocker dated one year out (${NEAR_FUTURE}) hard-fails"
fi

# (e) Malformed and impossible dates. Homebrew cannot parse these at all, so a
#     formula carrying one would not load — it is not a blocked state, it is a
#     broken one.
for bad_date in \
  "2026-02-30" \
  "2026-13-01" \
  "2026-00-10" \
  "2026-09-00" \
  "2026-09-31" \
  "2025-02-29" \
  "2026-9-2" \
  "26-09-02" \
  "2026/09/02" \
  "not-a-date" \
  ""; do
  BAD_FIXTURE="${WORKDIR}/case0c-bad.rb"
  blocked_with_date "${BAD_FIXTURE}" "${bad_date}"
  if "${METADATA_CHECK}" --mode pre-artifact "${BAD_FIXTURE}" >/dev/null 2>&1; then
    fail "case 0c: metadata gate accepted an invalid blocker date '${bad_date}'"
  else
    pass "case 0c: invalid blocker date '${bad_date}' hard-fails"
  fi
done

# (f) Leap-day handling must be genuinely calendrical, not a regex: 2024-02-29
#     exists and is in the past, so it is a legitimate blocker date.
LEAP_FIXTURE="${WORKDIR}/case0c-leap.rb"
blocked_with_date "${LEAP_FIXTURE}" "2024-02-29"
if "${METADATA_CHECK}" --mode pre-artifact "${LEAP_FIXTURE}" >/dev/null 2>&1; then
  pass "case 0c: a real past leap day (2024-02-29) is accepted"
else
  fail "case 0c: a real past leap day (2024-02-29) was wrongly rejected"
fi

# (g) A blocker with no date: argument at all never takes effect.
NODATE_FIXTURE="${WORKDIR}/case0c-no-date.rb"
sed 's/disable! date: "[^"]*", because:/disable! because:/' \
  "${BLOCKED_FIXTURE}" >"${NODATE_FIXTURE}"
if "${METADATA_CHECK}" --mode pre-artifact "${NODATE_FIXTURE}" >/dev/null 2>&1; then
  fail "case 0c: metadata gate accepted a blocker with no date: argument"
else
  pass "case 0c: a blocker with no date: argument hard-fails"
fi

# (h) A blocker carrying two date: values is ambiguous about when it takes
#     effect, so it is refused rather than silently resolved to the first one.
DUPDATE_FIXTURE="${WORKDIR}/case0c-two-dates.rb"
sed -E 's/(disable! date: )"[^"]*"/\1"2001-01-01", date: "2999-12-31"/' \
  "${BLOCKED_FIXTURE}" >"${DUPDATE_FIXTURE}"
if "${METADATA_CHECK}" --mode pre-artifact "${DUPDATE_FIXTURE}" >/dev/null 2>&1; then
  fail "case 0c: metadata gate accepted a blocker carrying two date: values"
else
  pass "case 0c: a blocker with two date: values hard-fails as ambiguous"
fi

# ---------------------------------------------------------------------------
echo "==> Case 1: complete, manifest-backed release is applied"
VERSION="9.9.9"
make_release "${VERSION}" "${TARGETS[@]}"
FORMULA="${WORKDIR}/case1.rb"
fresh_formula "${FORMULA}"
run_updater "${FORMULA}" "${VERSION}" >"${WORKDIR}/case1.log" 2>&1 ||
  { cat "${WORKDIR}/case1.log"; fail "case 1: updater rejected a valid release"; }

ruby -c "${FORMULA}" >/dev/null && pass "case 1: generated formula is valid Ruby"
if grep -Eq '^[[:space:]]*version[[:space:]]+"' "${FORMULA}"; then
  fail "case 1: updater emitted a redundant version stanza (breaks FormulaAudit/ComponentsOrder after 'head do')"
else
  pass "case 1: no version stanza generated; Homebrew infers it from the artifact URLs"
fi
url_count=$(grep -c "streamline-v${VERSION}-" "${FORMULA}" || true)
[ "${url_count}" -eq 4 ] && pass "case 1: four artifact URLs generated" ||
  fail "case 1: expected 4 artifact URLs, found ${url_count}"

# All four URLs must encode one and the same version: with no version stanza,
# that agreement is the only thing making the inferred version trustworthy.
url_versions=$(grep -Eo 'streamline-v[^"/]+-(aarch64-apple-darwin|x86_64-apple-darwin|aarch64-unknown-linux-gnu|x86_64-unknown-linux-gnu)\.tar\.gz' "${FORMULA}" |
  sed -E 's/^streamline-v//; s/-(aarch64|x86_64)-(apple-darwin|unknown-linux-gnu)\.tar\.gz$//' | sort -u)
if [ "${url_versions}" = "${VERSION}" ]; then
  pass "case 1: all four artifact URLs encode exactly one version (${VERSION})"
else
  fail "case 1: artifact URLs encode version(s) '$(printf '%s' "${url_versions}" | tr '\n' ' ')', expected only ${VERSION}"
fi
for target in "${TARGETS[@]}"; do
  expected=$(awk -v n="streamline-v${VERSION}-${target}.tar.gz" \
    '$2 == n { print $1 }' "${RELEASE_DIR}/checksums.txt")
  grep -qF "sha256 \"${expected}\"" "${FORMULA}" ||
    fail "case 1: manifest checksum for ${target} not written to formula"
done
pass "case 1: all four checksums match the manifest"
if grep -Eq '^[[:space:]]*disable![[:space:]]' "${FORMULA}"; then
  fail "case 1: fail-closed blocker survived a verified update"
else
  pass "case 1: blocker removed only after verified stable metadata was written"
fi
STREAMLINE_ALLOW_LOCAL_FIXTURES=1 "${METADATA_CHECK}" --mode release "${FORMULA}" >/dev/null &&
  pass "case 1: release metadata gate turns green" ||
  fail "case 1: release metadata gate still red after a valid update"
staged=$(find "${WORKDIR}" -maxdepth 1 -name '.case1.rb.staged.*' | wc -l | tr -d ' ')
[ "${staged}" = "0" ] && pass "case 1: no staged temp file left behind" ||
  fail "case 1: ${staged} staged temp file(s) left behind"

# ---------------------------------------------------------------------------
echo "==> Case 2: partial release (one archive missing) fails atomically"
MISSING_VERSION="10.0.0"
make_release "${MISSING_VERSION}" "${TARGETS[@]}"
rm -f "${RELEASE_DIR}/streamline-v${MISSING_VERSION}-${TARGETS[3]}.tar.gz"
FORMULA2="${WORKDIR}/case2.rb"
BASE2="${WORKDIR}/case2.base"
fresh_formula "${FORMULA2}"
cp "${FORMULA2}" "${BASE2}"
if run_updater "${FORMULA2}" "${MISSING_VERSION}" >/dev/null 2>&1; then
  fail "case 2: updater accepted a release with a missing archive"
else
  pass "case 2: updater rejected the incomplete release"
fi
assert_unchanged "case 2" "${FORMULA2}" "${BASE2}"

# ---------------------------------------------------------------------------
echo "==> Case 3: absent checksum manifest is refused"
NOMANIFEST_VERSION="10.1.0"
make_release "${NOMANIFEST_VERSION}" "${TARGETS[@]}"
rm -f "${RELEASE_DIR}/checksums.txt"
FORMULA3="${WORKDIR}/case3.rb"
BASE3="${WORKDIR}/case3.base"
fresh_formula "${FORMULA3}"
cp "${FORMULA3}" "${BASE3}"
if run_updater "${FORMULA3}" "${NOMANIFEST_VERSION}" >/dev/null 2>&1; then
  fail "case 3: updater proceeded without a checksum manifest"
else
  pass "case 3: updater refused to run without a checksum manifest"
fi
assert_unchanged "case 3" "${FORMULA3}" "${BASE3}"

# ---------------------------------------------------------------------------
echo "==> Case 4: archive that disagrees with the manifest is refused"
TAMPER_VERSION="10.2.0"
make_release "${TAMPER_VERSION}" "${TARGETS[@]}"
tamper_dir="${WORKDIR}/tamper"
mkdir -p "${tamper_dir}"
cp "${PAYLOAD}/streamline" "${tamper_dir}/"
printf 'tampered\n' >"${tamper_dir}/BUILDINFO"
tar -czf "${RELEASE_DIR}/streamline-v${TAMPER_VERSION}-${TARGETS[1]}.tar.gz" \
  -C "${tamper_dir}" streamline BUILDINFO
FORMULA4="${WORKDIR}/case4.rb"
BASE4="${WORKDIR}/case4.base"
fresh_formula "${FORMULA4}"
cp "${FORMULA4}" "${BASE4}"
if run_updater "${FORMULA4}" "${TAMPER_VERSION}" >/dev/null 2>&1; then
  fail "case 4: updater accepted an archive that mismatched the manifest"
else
  pass "case 4: checksum mismatch against the manifest rejected"
fi
assert_unchanged "case 4" "${FORMULA4}" "${BASE4}"

# ---------------------------------------------------------------------------
echo "==> Case 5: archive without the streamline binary is refused"
BADENTRY_VERSION="10.3.0"
bad_dir="${WORKDIR}/badentry"
mkdir -p "${bad_dir}"
printf 'not a binary\n' >"${bad_dir}/README"
make_release "${BADENTRY_VERSION}" "${TARGETS[@]}"
tar -czf "${RELEASE_DIR}/streamline-v${BADENTRY_VERSION}-${TARGETS[0]}.tar.gz" \
  -C "${bad_dir}" README
# Re-point the manifest entry at the replaced archive so only the *contents*
# are wrong; this isolates archive-entry validation from checksum validation.
manifest="${RELEASE_DIR}/checksums.txt"
bad_hash=$(cd "${RELEASE_DIR}" && shasum -a 256 "streamline-v${BADENTRY_VERSION}-${TARGETS[0]}.tar.gz" | awk '{print $1}')
awk -v n="streamline-v${BADENTRY_VERSION}-${TARGETS[0]}.tar.gz" -v h="${bad_hash}" \
  '$2 == n { print h "  " n; next } { print }' "${manifest}" >"${manifest}.new"
mv "${manifest}.new" "${manifest}"
FORMULA5="${WORKDIR}/case5.rb"
BASE5="${WORKDIR}/case5.base"
fresh_formula "${FORMULA5}"
cp "${FORMULA5}" "${BASE5}"
if run_updater "${FORMULA5}" "${BADENTRY_VERSION}" >/dev/null 2>&1; then
  fail "case 5: updater accepted an archive without the streamline binary"
else
  pass "case 5: archive entry validation rejected the archive"
fi
assert_unchanged "case 5" "${FORMULA5}" "${BASE5}"

# ---------------------------------------------------------------------------
echo "==> Case 6: signature verification is required by default"
SIG_VERSION="10.4.0"
make_release "${SIG_VERSION}" "${TARGETS[@]}"

FORMULA6="${WORKDIR}/case6.rb"
BASE6="${WORKDIR}/case6.base"
fresh_formula "${FORMULA6}"
cp "${FORMULA6}" "${BASE6}"
# Unset, not "0": the default must be "signature required".
if STREAMLINE_FORMULA="${FORMULA6}" \
  STREAMLINE_RELEASE_BASE_URL="file://${RELEASE_DIR}" \
  STREAMLINE_ALLOW_LOCAL_FIXTURES=1 \
  "${UPDATER}" "${SIG_VERSION}" >/dev/null 2>&1; then
  fail "case 6: updater accepted an unsigned manifest when the switch was unset"
else
  pass "case 6: unset STREAMLINE_REQUIRE_SIGNATURE defaults to required"
fi
assert_unchanged "case 6 (default)" "${FORMULA6}" "${BASE6}"

FORMULA6B="${WORKDIR}/case6b.rb"
BASE6B="${WORKDIR}/case6b.base"
fresh_formula "${FORMULA6B}"
cp "${FORMULA6B}" "${BASE6B}"
if REQUIRE_SIG=1 run_updater "${FORMULA6B}" "${SIG_VERSION}" >/dev/null 2>&1; then
  fail "case 6: updater accepted an unsigned manifest with signatures required"
else
  pass "case 6: unsigned manifest rejected when signature is required"
fi
assert_unchanged "case 6 (explicit)" "${FORMULA6B}" "${BASE6B}"

# ---------------------------------------------------------------------------
echo "==> Case 6c: STREAMLINE_REQUIRE_SIGNATURE accepts only '0' or '1'"
for bad_switch in "true" "yes" "2" "TRUE" "01" " 1" "no" "false"; do
  FORMULA6C="${WORKDIR}/case6c.rb"
  BASE6C="${WORKDIR}/case6c.base"
  fresh_formula "${FORMULA6C}"
  cp "${FORMULA6C}" "${BASE6C}"
  if REQUIRE_SIG="${bad_switch}" run_updater "${FORMULA6C}" "${SIG_VERSION}" >/dev/null 2>&1; then
    fail "case 6c: updater accepted STREAMLINE_REQUIRE_SIGNATURE='${bad_switch}'"
  fi
  cmp -s "${BASE6C}" "${FORMULA6C}" ||
    fail "case 6c: formula mutated for STREAMLINE_REQUIRE_SIGNATURE='${bad_switch}'"
done
pass "case 6c: truthy/typo'd signature switches are rejected, not interpreted"

# A rejected switch must fail before any network or filesystem work. Output is
# captured to a file rather than piped: with `set -o pipefail` the updater's
# non-zero exit status would otherwise mask a successful grep.
capture_updater() {
  local out="$1"
  shift
  run_updater "$@" >"${out}" 2>&1 || true
}

REQUIRE_SIG="true" capture_updater "${WORKDIR}/case6c.out" "${WORKDIR}/case6c.rb" "${SIG_VERSION}"
if grep -q "must be exactly '0' or '1'" "${WORKDIR}/case6c.out"; then
  pass "case 6c: rejection message names the accepted values"
else
  fail "case 6c: rejection message did not explain the accepted values"
fi

# ---------------------------------------------------------------------------
echo "==> Case 6d: required signatures pin the core workflow identity and OIDC issuer"
printf 'fixture signature\n' >"${RELEASE_DIR}/checksums.txt.sig"
printf 'fixture certificate\n' >"${RELEASE_DIR}/checksums.txt.pem"

FAKE_BIN="${WORKDIR}/fake-bin"
COSIGN_LOG="${WORKDIR}/cosign.log"
mkdir -p "${FAKE_BIN}"
cat >"${FAKE_BIN}/cosign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${COSIGN_LOG}"
expected_identity=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--certificate-identity" ]; then
    expected_identity="${2:-}"
    shift
  fi
  shift
done
if [ -n "${FAKE_CERTIFICATE_IDENTITY:-}" ] &&
  [ "${FAKE_CERTIFICATE_IDENTITY}" != "${expected_identity}" ]; then
  echo "certificate identity mismatch" >&2
  exit 1
fi
if [ "${FAKE_COSIGN_FAIL:-0}" = "1" ]; then
  echo "fixture cosign failure" >&2
  exit 1
fi
printf 'Verified OK\n'
EOF
chmod +x "${FAKE_BIN}/cosign"

run_cosign_verified() {
  local formula="$1" version="$2"
  PATH="${FAKE_BIN}:${PATH}" \
    COSIGN_LOG="${COSIGN_LOG}" \
    FAKE_CERTIFICATE_IDENTITY="${FAKE_CERTIFICATE_IDENTITY:-https://github.com/StreamlineLabs/streamline/.github/workflows/release.yml@refs/tags/v${version}}" \
    STREAMLINE_FORMULA="${formula}" \
    STREAMLINE_RELEASE_BASE_URL="file://${RELEASE_DIR}" \
    STREAMLINE_REQUIRE_SIGNATURE=1 \
    STREAMLINE_ALLOW_LOCAL_FIXTURES=1 \
    "${UPDATER}" "${version}"
}

FORMULA6D="${WORKDIR}/case6d.rb"
fresh_formula "${FORMULA6D}"
: >"${COSIGN_LOG}"
if run_cosign_verified "${FORMULA6D}" "${SIG_VERSION}" >/dev/null 2>&1; then
  pass "case 6d: a Cosign-verified checksums.txt release is accepted"
else
  fail "case 6d: updater rejected the valid Cosign fixture"
fi

EXPECTED_IDENTITY="https://github.com/StreamlineLabs/streamline/.github/workflows/release.yml@refs/tags/v${SIG_VERSION}"
for required_arg in \
  "verify-blob" \
  "--certificate" \
  "checksums.txt.pem" \
  "--signature" \
  "checksums.txt.sig" \
  "--certificate-identity ${EXPECTED_IDENTITY}" \
  "--certificate-oidc-issuer https://token.actions.githubusercontent.com" \
  "checksums.txt"; do
  if grep -Fq -- "${required_arg}" "${COSIGN_LOG}"; then
    pass "case 6d: cosign invocation includes '${required_arg}'"
  else
    fail "case 6d: cosign invocation omitted '${required_arg}'"
  fi
done

LOOKALIKE_FORMULA="${WORKDIR}/case6d-lookalike.rb"
LOOKALIKE_BASE="${WORKDIR}/case6d-lookalike.base"
fresh_formula "${LOOKALIKE_FORMULA}"
cp "${LOOKALIKE_FORMULA}" "${LOOKALIKE_BASE}"
LOOKALIKE_IDENTITY="https://github.com/StreamlineLabs/streamline/.github/workflows/release.yml@refs/tags/v10x4y0"
if FAKE_CERTIFICATE_IDENTITY="${LOOKALIKE_IDENTITY}" \
  run_cosign_verified "${LOOKALIKE_FORMULA}" "${SIG_VERSION}" >/dev/null 2>&1; then
  fail "case 6d: lookalike certificate tag v10x4y0 matched v${SIG_VERSION}"
else
  pass "case 6d: lookalike certificate tag v10x4y0 is rejected"
fi
assert_unchanged \
  "case 6d lookalike identity" "${LOOKALIKE_FORMULA}" "${LOOKALIKE_BASE}"

# Missing either keyless verification asset is fatal and leaves the formula
# untouched.
for missing in checksums.txt.sig checksums.txt.pem; do
  FORMULA_MISSING="${WORKDIR}/case6d-missing-${missing}.rb"
  BASE_MISSING="${WORKDIR}/case6d-missing-${missing}.base"
  fresh_formula "${FORMULA_MISSING}"
  cp "${FORMULA_MISSING}" "${BASE_MISSING}"
  mv "${RELEASE_DIR}/${missing}" "${RELEASE_DIR}/${missing}.saved"
  if run_cosign_verified "${FORMULA_MISSING}" "${SIG_VERSION}" >/dev/null 2>&1; then
    fail "case 6d: updater accepted a release without ${missing}"
  else
    pass "case 6d: missing ${missing} fails closed"
  fi
  mv "${RELEASE_DIR}/${missing}.saved" "${RELEASE_DIR}/${missing}"
  assert_unchanged "case 6d missing ${missing}" "${FORMULA_MISSING}" "${BASE_MISSING}"
done

FORMULA_COSIGN_FAIL="${WORKDIR}/case6d-cosign-fail.rb"
BASE_COSIGN_FAIL="${WORKDIR}/case6d-cosign-fail.base"
fresh_formula "${FORMULA_COSIGN_FAIL}"
cp "${FORMULA_COSIGN_FAIL}" "${BASE_COSIGN_FAIL}"
if FAKE_COSIGN_FAIL=1 run_cosign_verified \
  "${FORMULA_COSIGN_FAIL}" "${SIG_VERSION}" >/dev/null 2>&1; then
  fail "case 6d: updater ignored a Cosign verification failure"
else
  pass "case 6d: Cosign verification failure blocks the update"
fi
assert_unchanged \
  "case 6d cosign failure" "${FORMULA_COSIGN_FAIL}" "${BASE_COSIGN_FAIL}"

if grep -Eq 'STREAMLINE_GPG_|gpg|VALIDSIG|keyring' "${UPDATER}"; then
  fail "case 6d: updater still carries the conflicting GPG-only contract"
else
  pass "case 6d: updater contains no GPG-only trust-anchor requirement"
fi

# ---------------------------------------------------------------------------
echo "==> Case 7: malformed version strings are rejected before any I/O"
for bad in "0.3" "v0.3.0" "0.3.0; touch pwned" "latest" "0.3.0 && ls"; do
  FORMULA7="${WORKDIR}/case7.rb"
  BASE7="${WORKDIR}/case7.base"
  fresh_formula "${FORMULA7}"
  cp "${FORMULA7}" "${BASE7}"
  if run_updater "${FORMULA7}" "${bad}" >/dev/null 2>&1; then
    fail "case 7: updater accepted invalid version '${bad}'"
  fi
  cmp -s "${BASE7}" "${FORMULA7}" || fail "case 7: formula mutated for '${bad}'"
done
pass "case 7: all malformed versions rejected with no formula mutation"

# ---------------------------------------------------------------------------
echo "==> Case 8: metadata gate rejects untrustworthy checksum states"
for bad_line in \
  '  sha256 "PLACEHOLDER_SHA256_ARM64_DARWIN"' \
  '  sha256 :no_check' \
  '  sha256 "deadbeef"' \
  '  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"' \
  '  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'; do
  FORMULA8="${WORKDIR}/case8.rb"
  fresh_formula "${FORMULA8}"
  printf '%s\n' "${bad_line}" >>"${FORMULA8}"
  if "${METADATA_CHECK}" --mode pre-artifact "${FORMULA8}" >/dev/null 2>&1; then
    fail "case 8: metadata gate accepted '${bad_line}'"
  fi
done
pass "case 8: placeholder, :no_check, malformed, empty-archive and filler checksums all hard-fail"

# ---------------------------------------------------------------------------
echo "==> Case 9: a half-generated stable stanza is rejected"
FORMULA9="${WORKDIR}/case9.rb"
make_release "11.0.0" "${TARGETS[@]}"
fresh_formula "${FORMULA9}"
REQUIRE_SIG=0 run_updater "${FORMULA9}" "11.0.0" >/dev/null 2>&1 ||
  fail "case 9: setup update failed"
# Drop one of the four artifact URL/sha pairs to simulate a truncated stanza.
grep -v "x86_64-unknown-linux-gnu" "${FORMULA9}" >"${FORMULA9}.partial"
if STREAMLINE_ALLOW_LOCAL_FIXTURES=1 "${METADATA_CHECK}" --mode pre-artifact "${FORMULA9}.partial" >/dev/null 2>&1; then
  fail "case 9: metadata gate accepted a partially generated stanza"
else
  pass "case 9: partially generated stable metadata hard-fails"
fi

# ---------------------------------------------------------------------------
echo "==> Case 10: the version is derived from the artifact URLs, not a stanza"
FORMULA10="${WORKDIR}/case10.rb"
make_release "12.0.0" "${TARGETS[@]}"
fresh_formula "${FORMULA10}"
REQUIRE_SIG=0 run_updater "${FORMULA10}" "12.0.0" >/dev/null 2>&1 ||
  fail "case 10: setup update failed"

# (a) A re-added explicit version stanza is refused, even when it agrees with
#     the URLs: it is redundant and, in the generated region, out of order.
WITHVERSION="${WORKDIR}/case10-version.rb"
awk -v b="${BEGIN_MARKER}" '
  index($0, b) { print; print "  version \"12.0.0\""; next }
  { print }
' "${FORMULA10}" >"${WITHVERSION}"
if STREAMLINE_ALLOW_LOCAL_FIXTURES=1 "${METADATA_CHECK}" --mode release "${WITHVERSION}" >/dev/null 2>&1; then
  fail "case 10: metadata gate accepted a redundant, out-of-order version stanza"
else
  pass "case 10: explicit version stanza is refused (URL inference makes it redundant)"
fi

# (b) Artifact URLs that disagree on the version are refused, since nothing
#     else records the version any more.
MIXEDVERSION="${WORKDIR}/case10-mixed.rb"
sed 's/streamline-v12\.0\.0-x86_64-unknown-linux-gnu\.tar\.gz/streamline-v12.0.1-x86_64-unknown-linux-gnu.tar.gz/' \
  "${FORMULA10}" >"${MIXEDVERSION}"
if STREAMLINE_ALLOW_LOCAL_FIXTURES=1 "${METADATA_CHECK}" --mode release "${MIXEDVERSION}" >/dev/null 2>&1; then
  fail "case 10: metadata gate accepted artifact URLs encoding two different versions"
else
  pass "case 10: artifact URLs disagreeing on the version hard-fail"
fi

# (c) The consistent, stanza-free formula is what the gate accepts, and it
#     reports the version it inferred.
#
#     The checker's output is captured to a file and grepped afterwards rather
#     than piped straight into `grep -q`. Under `set -o pipefail`, `grep -q`
#     exits the moment it matches, and the checker — which prints three more
#     lines after the one being matched — is then killed by SIGPIPE and exits
#     141, failing the pipeline and reporting a spurious test failure. Capture
#     first, match second: the checker always runs to completion, and its exit
#     status and its output are asserted separately and deterministically.
CASE10_OUT="${WORKDIR}/case10-release.out"
if STREAMLINE_ALLOW_LOCAL_FIXTURES=1 "${METADATA_CHECK}" --mode release "${FORMULA10}" \
  >"${CASE10_OUT}" 2>&1 && grep -q "agree on version 12.0.0" "${CASE10_OUT}"; then
  pass "case 10: gate reports the version inferred from all four URLs"
else
  cat "${CASE10_OUT}" >&2
  fail "case 10: gate did not report a single inferred version"
fi

# ---------------------------------------------------------------------------
# Static checks on scripts/validate-formula.sh. It needs Homebrew to run, which
# this hermetic suite deliberately does not use, so its tap-construction
# contract is asserted by inspection — the same approach case 6d takes for the
# Cosign identity and issuer invocation.
echo "==> Case 11: brew validation taps a verified copy, never a symlink"
VALIDATOR="${ROOT}/scripts/validate-formula.sh"
if grep -Eq '^[[:space:]]*ln -s' "${VALIDATOR}"; then
  fail "case 11: validate-formula.sh still symlinks the formula into the tap; Homebrew realpath-resolves it back out of the tap and rejects it"
else
  pass "case 11: no symlink is created in the ephemeral tap"
fi
if grep -q 'cp -p "${FORMULA_PATH}" "${TAP_FORMULA}"' "${VALIDATOR}"; then
  pass "case 11: the tapped formula is a real copy of the repository formula"
else
  fail "case 11: validate-formula.sh does not copy the formula into the tap"
fi
if grep -q 'cmp -s "${FORMULA_PATH}" "${TAP_FORMULA}"' "${VALIDATOR}"; then
  pass "case 11: the copy is compared against the repository formula with cmp"
else
  fail "case 11: the tapped copy is never compared against the repository formula"
fi
before_count=$(grep -c 'assert_copy_matches "before validation"' "${VALIDATOR}" || true)
[ "${before_count}" -eq 1 ] &&
  pass "case 11: copy is verified before any brew step reads it" ||
  fail "case 11: expected exactly one pre-validation cmp, found ${before_count}"
after_count=$(grep -c 'assert_copy_matches "after ' "${VALIDATOR}" || true)
[ "${after_count}" -ge 4 ] &&
  pass "case 11: copy is re-verified after style, audit and both install paths (${after_count} checks)" ||
  fail "case 11: expected post-step cmp after style, audit and both install paths, found ${after_count}"

# The guard must abort, not warn: a mismatch means the green result describes
# bytes that are not checked in. (Extracted to a file first: `awk | grep -q`
# has the same SIGPIPE-under-pipefail hazard as case 10 above.)
ASSERT_COPY_FN="${WORKDIR}/assert-copy-matches.fn"
awk '/^assert_copy_matches\(\)/,/^}/' "${VALIDATOR}" >"${ASSERT_COPY_FN}"
if grep -q 'exit 1' "${ASSERT_COPY_FN}"; then
  pass "case 11: a stale or diverged copy aborts the run"
else
  fail "case 11: copy divergence does not abort the run"
fi

# ---------------------------------------------------------------------------
# The public source/HEAD build contract (`option "with-moonshot"` plus the
# conditional Cargo feature arguments) lives outside the generated region, so
# regeneration must never disturb it. Behaviour of the option itself is proved
# by scripts/test-formula-options.rb, which loads the formula against a stub
# Homebrew DSL and runs its real `install` method; here it is re-run against a
# *regenerated* formula so the guarantee covers the post-artifact state too.
echo "==> Case 12: regeneration preserves the --with-moonshot HEAD build contract"
OPTIONS_TEST="${ROOT}/scripts/test-formula-options.rb"
FORMULA12="${WORKDIR}/case12.rb"
make_release "13.0.0" "${TARGETS[@]}"
fresh_formula "${FORMULA12}"

option_before=$(grep -c '^[[:space:]]*option "with-moonshot"' "${FORMULA12}" || true)
if [ "${option_before}" -eq 1 ]; then
  pass "case 12: the blocked fixture declares the with-moonshot option"
else
  fail "case 12: expected the with-moonshot option in the blocked fixture, found ${option_before}"
fi

if ruby "${OPTIONS_TEST}" "${FORMULA12}" >"${WORKDIR}/case12-blocked.log" 2>&1; then
  pass "case 12: option contract holds in the blocked (pre-artifact) state"
else
  cat "${WORKDIR}/case12-blocked.log" >&2
  fail "case 12: option contract broken in the blocked (pre-artifact) state"
fi

REQUIRE_SIG=0 run_updater "${FORMULA12}" "13.0.0" >"${WORKDIR}/case12.log" 2>&1 ||
  { cat "${WORKDIR}/case12.log" >&2; fail "case 12: setup update failed"; }

option_after=$(grep -c '^[[:space:]]*option "with-moonshot"' "${FORMULA12}" || true)
if [ "${option_after}" -eq 1 ]; then
  pass "case 12: the option survives regeneration exactly once"
else
  fail "case 12: expected exactly one with-moonshot option after regeneration, found ${option_after}"
fi

cond_after=$(grep -c 'build.with?("moonshot")' "${FORMULA12}" || true)
if [ "${cond_after}" -eq 1 ]; then
  pass "case 12: the conditional cargo feature code survives regeneration"
else
  fail "case 12: expected one build.with?(\"moonshot\") conditional, found ${cond_after}"
fi

feature_after=$(grep -c -- '"--features", "moonshot"' "${FORMULA12}" || true)
if [ "${feature_after}" -eq 1 ]; then
  pass "case 12: '--features moonshot' is passed exactly once after regeneration"
else
  fail "case 12: expected one '--features, moonshot' argument pair, found ${feature_after}"
fi

# The contract must not have been swept into the generated region, where the
# next regeneration would delete it. (Region extracted to a file first: piping
# `region_of` into `grep -q` risks the same SIGPIPE/pipefail flake as case 10.)
CASE12_REGION="${WORKDIR}/case12-region.txt"
region_of "${FORMULA12}" >"${CASE12_REGION}"
if grep -q 'moonshot' "${CASE12_REGION}"; then
  fail "case 12: the moonshot contract ended up inside the generated region"
else
  pass "case 12: the contract stays outside the generated region"
fi

if grep -Eq '^[[:space:]]*disable![[:space:]]' "${FORMULA12}"; then
  fail "case 12: blocker survived a verified update"
else
  pass "case 12: regeneration replaced the blocker while keeping the HEAD contract"
fi

if ruby "${OPTIONS_TEST}" "${FORMULA12}" >"${WORKDIR}/case12-release.log" 2>&1; then
  pass "case 12: option contract still holds against the regenerated (release) formula"
else
  cat "${WORKDIR}/case12-release.log" >&2
  fail "case 12: option contract broken by regeneration"
fi

# Negative control: the contract suite must actually fail when the contract is
# removed, otherwise the checks above prove nothing.
STRIPPED="${WORKDIR}/case12-stripped.rb"
grep -v '^[[:space:]]*option "with-moonshot"' "${FORMULA12}" |
  grep -v '^[[:space:]]*"Include experimental moonshot features' >"${STRIPPED}"
if ruby "${OPTIONS_TEST}" "${STRIPPED}" >/dev/null 2>&1; then
  fail "case 12: option contract suite passed a formula with the option deleted"
else
  pass "case 12: deleting the option makes the contract suite fail (negative control)"
fi

# ---------------------------------------------------------------------------
echo "==> Case 13: docs and Makefile expose truthful post-artifact HEAD commands"
HEAD_CMD="brew install --HEAD streamlinelabs/tap/streamline"
MOONSHOT_CMD="brew install --HEAD --with-moonshot streamlinelabs/tap/streamline"

for doc in "README.md" "CONTRIBUTING.md" "CLAUDE.md"; do
  if grep -qF "${MOONSHOT_CMD}" "${ROOT}/${doc}"; then
    pass "case 13: ${doc} documents '${MOONSHOT_CMD}'"
  else
    fail "case 13: ${doc} does not document the --with-moonshot HEAD command"
  fi
  if grep -qF "${HEAD_CMD}" "${ROOT}/${doc}"; then
    pass "case 13: ${doc} documents the plain HEAD command"
  else
    fail "case 13: ${doc} does not document the plain HEAD command"
  fi
  # Truthfulness: HEAD commands must not be advertised as working today. Each
  # document has to keep saying, explicitly, that every install path is blocked
  # while the formula carries its fail-closed blocker.
  if grep -q 'disable!' "${ROOT}/${doc}" &&
    grep -Eqi 'blocked|fails closed|fail closed|disabled' "${ROOT}/${doc}"; then
    pass "case 13: ${doc} keeps the pre-artifact disablement explicit"
  else
    fail "case 13: ${doc} no longer states that installs are blocked pre-artifact"
  fi
done

if grep -q '^test-install-head-moonshot:' "${ROOT}/Makefile"; then
  pass "case 13: Makefile exposes a test-install-head-moonshot target"
else
  fail "case 13: Makefile has no target for the --with-moonshot HEAD install"
fi
if grep -q 'validate-formula.sh --mode $(MODE) --install-head --with-moonshot' "${ROOT}/Makefile"; then
  pass "case 13: the Makefile target passes --with-moonshot through to the validator"
else
  fail "case 13: the Makefile target does not pass --with-moonshot to validate-formula.sh"
fi
if grep -q 'test-options:' "${ROOT}/Makefile"; then
  pass "case 13: Makefile exposes the source-level option contract tests"
else
  fail "case 13: Makefile does not expose the option contract tests"
fi
if grep -q 'expected$' "${ROOT}/Makefile" || grep -qi 'blocked while the formula is disabled' "${ROOT}/Makefile"; then
  pass "case 13: Makefile states the install targets are blocked pre-artifact"
else
  fail "case 13: Makefile no longer states that install targets are blocked pre-artifact"
fi

# The validator must actually forward the user-facing flag to brew.
if grep -q 'HEAD_ARGS+=(--with-moonshot)' "${VALIDATOR}"; then
  pass "case 13: validate-formula.sh forwards --with-moonshot to 'brew install --HEAD'"
else
  fail "case 13: validate-formula.sh does not forward --with-moonshot to brew"
fi

# ---------------------------------------------------------------------------
echo "==> Case 14: manual release CI installs the verified stable artifact"
RELEASE_GATE="${WORKDIR}/release-gate.yml"
sed -n '/^  release-gate:/,$p' "${CI_WORKFLOW}" >"${RELEASE_GATE}"

if grep -qF "if: github.event_name == 'workflow_dispatch' && inputs.mode == 'release'" "${RELEASE_GATE}"; then
  pass "case 14: strict release gate runs only for an explicit release-mode dispatch"
else
  fail "case 14: strict release gate is not limited to release-mode workflow_dispatch"
fi
if grep -qF 'runs-on: macos-latest' "${RELEASE_GATE}"; then
  pass "case 14: strict release gate runs on macOS with Homebrew available"
else
  fail "case 14: strict release gate does not run on macOS"
fi
if grep -qF './scripts/validate-formula.sh --mode release --install-stable' "${RELEASE_GATE}"; then
  pass "case 14: strict release gate downloads, verifies, installs and tests the stable formula"
else
  fail "case 14: strict release gate does not exercise the stable install path"
fi
if grep -q 'continue-on-error' "${RELEASE_GATE}"; then
  fail "case 14: strict release gate suppresses a real publication failure"
else
  pass "case 14: strict release gate remains fail-closed"
fi

echo
if [ "${FAILED}" -ne 0 ]; then
  echo "Formula updater fixture tests FAILED" >&2
  exit 1
fi
echo "Formula updater fixture tests passed"
