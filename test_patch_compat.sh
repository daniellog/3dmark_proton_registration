#!/usr/bin/env bash
#
# test_patch_compat.sh - regression tests for patch_3dmark_compat.sh
#
# Uses fixtures/make_choros_fixture.py to build a synthetic choros.jar, so the
# tests run without a real 3DMark installation.
#
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHER="$SELF_DIR/patch_3dmark_compat.sh"
FIXTURE_PY="$SELF_DIR/fixtures/make_choros_fixture.py"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/3dmarkpatchtest.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
pass() { printf 'PASS: %s\n' "$*"; }

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
[ -x "$PATCHER" ] || { echo "missing $PATCHER" >&2; exit 1; }
[ -f "$FIXTURE_PY" ] || { echo "missing $FIXTURE_PY" >&2; exit 1; }

FIXTURE_JAR="$TMP_DIR/choros.jar"
python3 "$FIXTURE_PY" "$FIXTURE_JAR" || { echo "fixture failed" >&2; exit 1; }

export DANLAN_3DMARK_STEAM_ROOTS="$TMP_DIR/no-library"
mkdir -p "$DANLAN_3DMARK_STEAM_ROOTS"

new_game() {
  local d="$TMP_DIR/game-$1"
  mkdir -p "$d/bin/x64"
  cp "$FIXTURE_JAR" "$d/bin/x64/choros.jar"
  printf '%s\n' "$d"
}

# ---------------------------------------------------------------------------
# Test 1: patch applies, backup created, method body neutralised
# ---------------------------------------------------------------------------
G="$(new_game 1)"
JAR="$G/bin/x64/choros.jar"
orig_size=$(stat -c%s "$JAR")
out=$("$PATCHER" -g "$G" 2>&1)
[ -f "$G/bin/x64/choros.jar.orig" ] || fail "1: pristine backup not created"
[ "$(stat -c%s "$JAR")" -lt "$orig_size" ] || fail "1: patched jar did not shrink"
python3 - "$JAR" <<'PY' || fail "1: patched class lost the 'return' body"
import sys, zipfile
d = zipfile.ZipFile(sys.argv[1]).read("com/futuremark/choros/service/ProductStateServiceImpl.class")
assert d[:4] == b"\xca\xfe\xba\xbe"
assert b"\xb1" in d
PY
case "$out" in *"Patched launcher installed"*) ;; *) fail "1: missing success message";; esac
pass "1: patch applies, backup created, jar rewritten"

# ---------------------------------------------------------------------------
# Test 2: second run is a no-op
# ---------------------------------------------------------------------------
sum1=$(sha256sum "$JAR" | cut -d' ' -f1)
out=$("$PATCHER" -g "$G" 2>&1)
sum2=$(sha256sum "$JAR" | cut -d' ' -f1)
[ "$sum1" = "$sum2" ] || fail "2: rerun modified the jar"
case "$out" in *"Already patched"*) ;; *) fail "2: rerun not reported as patched";; esac
pass "2: repeated run is a no-op"

# ---------------------------------------------------------------------------
# Test 3: --dry-run changes nothing
# ---------------------------------------------------------------------------
G3="$(new_game 3)"
J3="$G3/bin/x64/choros.jar"
sum1=$(sha256sum "$J3" | cut -d' ' -f1)
out=$("$PATCHER" -g "$G3" --dry-run 2>&1)
sum2=$(sha256sum "$J3" | cut -d' ' -f1)
[ "$sum1" = "$sum2" ] || fail "3: dry-run modified the jar"
[ ! -f "$J3.orig" ] || fail "3: dry-run created a backup"
case "$out" in *"[dry-run]"*) ;; *) fail "3: dry-run said nothing useful";; esac
pass "3: --dry-run is read-only"

# ---------------------------------------------------------------------------
# Test 4: --revert restores the pristine jar byte for byte
# ---------------------------------------------------------------------------
G4="$(new_game 4)"
J4="$G4/bin/x64/choros.jar"
"$PATCHER" -g "$G4" >/dev/null 2>&1
"$PATCHER" -g "$G4" --revert >/dev/null 2>&1
cmp -s "$J4" "$FIXTURE_JAR" || fail "4: revert did not restore the original jar"
out=$("$PATCHER" -g "$G4" --revert 2>&1)
case "$out" in *"Already pristine"*) ;; *) fail "4: second revert not idempotent";; esac
pass "4: --revert restores byte-identical jar"

# ---------------------------------------------------------------------------
# Test 5: missing installation exits 3
# ---------------------------------------------------------------------------
"$PATCHER" -g "$TMP_DIR/nope" -q >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] || fail "5: missing install exited $rc (want 3)"
pass "5: missing installation exits 3"

# ---------------------------------------------------------------------------
# Test 6: patcher is idempotent across apply -> revert -> apply
# ---------------------------------------------------------------------------
G6="$(new_game 6)"
J6="$G6/bin/x64/choros.jar"
"$PATCHER" -g "$G6" >/dev/null 2>&1
sum_a=$(sha256sum "$J6" | cut -d' ' -f1)
"$PATCHER" -g "$G6" --revert >/dev/null 2>&1
"$PATCHER" -g "$G6" >/dev/null 2>&1
sum_b=$(sha256sum "$J6" | cut -d' ' -f1)
[ "$sum_a" = "$sum_b" ] || fail "6: apply -> revert -> apply is not reproducible"
pass "6: apply/revert cycle is reproducible"

# ---------------------------------------------------------------------------
# Test 7: --install asks Steam for the game and patches once it appears
# ---------------------------------------------------------------------------
LIB7="$TMP_DIR/lib7"
mkdir -p "$LIB7" "$TMP_DIR/bin7"
cat >"$TMP_DIR/bin7/steam" <<EOF
#!/bin/sh
case "\$1" in
  steam://install/223850) ;;
  *) exit 1 ;;
esac
d="$LIB7/steamapps/common/3DMark/bin/x64"
mkdir -p "\$d"
cp "$FIXTURE_JAR" "\$d/choros.jar"
EOF
chmod +x "$TMP_DIR/bin7/steam"
out=$(DANLAN_3DMARK_STEAM_ROOTS="$LIB7" PATH="$TMP_DIR/bin7:$PATH" \
      "$PATCHER" --install --install-timeout 30 2>&1)
rc=$?
G7="$LIB7/steamapps/common/3DMark"
[ "$rc" -eq 0 ] || fail "7: --install exited $rc"
[ -f "$G7/bin/x64/choros.jar.orig" ] || fail "7: downloaded install was not patched"
cmp -s "$G7/bin/x64/choros.jar" "$FIXTURE_JAR" && fail "7: jar still pristine"
pass "7: --install downloads via Steam and patches the result"

# ---------------------------------------------------------------------------
# Test 8: --install times out with exit 6 when Steam never delivers
# ---------------------------------------------------------------------------
mkdir -p "$TMP_DIR/bin8" "$TMP_DIR/lib8"
printf '#!/bin/sh\nexit 0\n' >"$TMP_DIR/bin8/steam"
chmod +x "$TMP_DIR/bin8/steam"
out=$(DANLAN_3DMARK_STEAM_ROOTS="$TMP_DIR/lib8" PATH="$TMP_DIR/bin8:$PATH" \
      "$PATCHER" --install --install-timeout 1 2>&1)
rc=$?
[ "$rc" -eq 6 ] || fail "8: install timeout exited $rc (want 6)"
case "$out" in *"timed out"*) ;; *) fail "8: no timeout message";; esac
pass "8: --install timeout exits 6"

# ---------------------------------------------------------------------------
# Test 9: --install-only does not touch an existing install
# ---------------------------------------------------------------------------
G9="$(new_game 9)"
sum1=$(sha256sum "$G9/bin/x64/choros.jar" | cut -d' ' -f1)
out=$(DANLAN_3DMARK_STEAM_ROOTS="$TMP_DIR/game-9/.." "$PATCHER" -g "$G9" --install-only 2>&1)
rc=$?
sum2=$(sha256sum "$G9/bin/x64/choros.jar" | cut -d' ' -f1)
[ "$rc" -eq 0 ] || fail "9: --install-only exited $rc"
[ "$sum1" = "$sum2" ] || fail "9: --install-only modified the jar"
[ ! -f "$G9/bin/x64/choros.jar.orig" ] || fail "9: --install-only created a backup"
pass "9: --install-only leaves the installation untouched"

# ---------------------------------------------------------------------------
# Test 10: --no-wait starts the download and returns without patching
# ---------------------------------------------------------------------------
LIB10="$TMP_DIR/lib10"
mkdir -p "$LIB10" "$TMP_DIR/bin10"
cat >"$TMP_DIR/bin10/steam" <<EOF
#!/bin/sh
sleep 1
d="$LIB10/steamapps/common/3DMark/bin/x64"
mkdir -p "\$d"
cp "$FIXTURE_JAR" "\$d/choros.jar"
EOF
chmod +x "$TMP_DIR/bin10/steam"
out=$(DANLAN_3DMARK_STEAM_ROOTS="$LIB10" PATH="$TMP_DIR/bin10:$PATH" \
      "$PATCHER" --install --no-wait 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "10: --no-wait exited $rc"
case "$out" in *"download started"*) ;; *) fail "10: no 'download started' message";; esac
[ ! -f "$LIB10/steamapps/common/3DMark/bin/x64/choros.jar.orig" ] \
  || fail "10: --no-wait patched immediately"
sleep 2   # let the detached stub Steam process finish before cleanup
pass "10: --no-wait starts the download and exits"

# ---------------------------------------------------------------------------
# Test 11: --check reports installation state
# ---------------------------------------------------------------------------
G11="$(new_game 11)"
"$PATCHER" -g "$G11" --check >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "11: --check on installed game exited $rc"
"$PATCHER" -g "$TMP_DIR/absent" --check >/dev/null 2>&1
rc=$?
[ "$rc" -eq 3 ] || fail "11: --check on missing game exited $rc"
[ ! -f "$G11/bin/x64/choros.jar.orig" ] || fail "11: --check created a backup"
pass "11: --check reports installation state without side effects"

echo
if [ "$FAILED" -ne 0 ]; then
  echo "Some tests failed."
  exit 1
fi
echo "All tests passed successfully."
