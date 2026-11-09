#!/usr/bin/env bash
#
# test_patch_compat.sh - regression tests for patch_3dmark_compat.sh
#
# Builds a synthetic choros.jar containing a stub
# ProductStateServiceImpl.checkCpusForInstructionsSetRequirement method, so the
# tests run without a real 3DMark installation.
#
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHER="$SELF_DIR/patch_3dmark_compat.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/3dmarkpatchtest.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

FAILED=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }
pass() { printf 'PASS: %s\n' "$*"; }

command -v python3 >/dev/null || { echo "python3 required" >&2; exit 1; }
[ -x "$PATCHER" ] || { echo "missing $PATCHER" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Fixture: a minimal but structurally valid Java class file
# ---------------------------------------------------------------------------
cat >"$TMP_DIR/mkfixture.py" <<'PYEOF'
import struct
import sys
import zipfile

METHOD = "checkCpusForInstructionsSetRequirement"
DESC = ("(Lcom/google/common/collect/ImmutableList$Builder;"
        "Lcom/futuremark/izzy/results/systeminfo/SystemInfo;"
        "Lcom/futuremark/izzy/results/systeminfo/InstructionSet;)V")


def u2(v):
    return struct.pack(">H", v)


def utf8(s):
    b = s.encode()
    return b"\x01" + u2(len(b)) + b


# constant pool: 1=Test, 2=java/lang/Object, 3=Class(2), 4=method, 5=descriptor,
# 6=Code, 7=Class(1)
pool = [utf8("Test"), utf8("java/lang/Object"), b"\x07" + u2(2), utf8(METHOD),
        utf8(DESC), utf8("Code"), b"\x07" + u2(1)]
out = b"\xca\xfe\xba\xbe" + u2(0) + u2(52) + u2(len(pool) + 1) + b"".join(pool)
out += u2(0x0021) + u2(7) + u2(2)          # access, this=Test, super=Object
out += u2(0)                               # interfaces
out += u2(0)                               # fields
code = b"\x00\x00\x00\x00\xb1"             # nop*4; return
body = u2(0) + u2(1) + struct.pack(">I", len(code)) + code + u2(0) + u2(0)
attributes = u2(1) + u2(6) + struct.pack(">I", len(body)) + body
method = u2(0x000a) + u2(4) + u2(5) + attributes
out += u2(1) + method                      # one method
out += u2(0)                               # class attributes

with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("com/futuremark/choros/service/ProductStateServiceImpl.class", out)
    z.writestr("META-INF/MANIFEST.MF", b"Manifest-Version: 1.0\n")
PYEOF

python3 "$TMP_DIR/mkfixture.py" "$TMP_DIR/choros.jar" || { echo "fixture failed" >&2; exit 1; }

new_game() {
  local d="$TMP_DIR/game-$1"
  mkdir -p "$d/bin/x64"
  cp "$TMP_DIR/choros.jar" "$d/bin/x64/choros.jar"
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
assert b"\x00\x0d" + b"\x00\x00\x00\x00\x00" not in d  # sanity
assert d.count(b"\xb1") >= 1
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
cmp -s "$J4" "$TMP_DIR/choros.jar" || fail "4: revert did not restore the original jar"
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

echo
if [ "$FAILED" -ne 0 ]; then
  echo "Some tests failed."
  exit 1
fi
echo "All tests passed successfully."
