#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SETUP="$SCRIPT_DIR/setup_3dmark.sh"

TMP_DIR=$(mktemp -d /tmp/3dmark_test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# Stub clipboard tools so a real desktop clipboard never leaks into tests
STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
for t in wl-paste xclip xsel; do
  printf '#!/bin/sh\nexit 1\n' > "$STUB_BIN/$t"
  chmod +x "$STUB_BIN/$t"
done
export PATH="$STUB_BIN:$PATH"
unset WAYLAND_DISPLAY DISPLAY

UL='Software\\UL\\3DMark'
FM='Software\\Futuremark\\3DMark'

KEY1='3DM-ICF-AB12-CD34-EF56-7890'
KEY2='3DM-ICF-ZZ99-YY88-XX77-6655'
SPY='3DM-SPY-1111-2222-3333-4444'
PR='3DM-PR-5555-6666-7777-8888'

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

new_prefix() {
  mkdir -p "$1"
  cat > "$1/user.reg" <<'EOF'
WINE REGISTRY Version 2
;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

[Software\\Wine\\DllOverrides] 1793687163
#time=1dd6b5c33adccb0
"d3dcompiler_43"="native,builtin"

[Volatile Environment] 1794254365
#time=1dd7084d26ca970
"USERNAME"="steamuser"
EOF
}

# Read a value from a section of a user.reg file (ENVIRON avoids awk -v escapes)
reg_get() {
  SEC="$2" NM="$3" awk '
    /^\[/ { h=$0; sub(/^\[/,"",h); sub(/\].*$/,"",h); insec=(h==ENVIRON["SEC"]); next }
    insec && index($0, "\"" ENVIRON["NM"] "\"=") == 1 {
      v = substr($0, length(ENVIRON["NM"]) + 4); sub(/^"/,"",v); sub(/"$/,"",v); print v; exit
    }' "$1"
}

# Count occurrences of a value name inside one section
reg_count() {
  SEC="$2" NM="$3" awk '
    /^\[/ { h=$0; sub(/^\[/,"",h); sub(/\].*$/,"",h); insec=(h==ENVIRON["SEC"]); next }
    insec && index($0, "\"" ENVIRON["NM"] "\"=") == 1 { n++ }
    END { print n + 0 }' "$1"
}

run() { "$SETUP" "$@" 2>&1; }

# ---------------------------------------------------------------------------
# Test 1: insert into both sections on a fresh prefix
# ---------------------------------------------------------------------------
P="$TMP_DIR/t1"; new_prefix "$P"
out=$(run -p "$P" -k "$KEY1")
grep -Fq "[$UL]" "$P/user.reg" || fail "1: UL section missing"
grep -Fq "[$FM]" "$P/user.reg" || fail "1: Futuremark section missing"
[[ "$(reg_get "$P/user.reg" "$UL" KeyCode)" == "$KEY1" ]] || fail "1: UL key wrong"
[[ "$(reg_get "$P/user.reg" "$FM" KeyCode)" == "$KEY1" ]] || fail "1: FM key wrong"
[[ "$out" != *"$KEY1"* ]] || fail "1: key was not masked in output"
pass "1: insert into UL + Futuremark, key masked"

# ---------------------------------------------------------------------------
# Test 2: update existing key without duplicating values
# ---------------------------------------------------------------------------
out=$(run -p "$P" -k "$KEY2")
[[ "$(reg_get "$P/user.reg" "$UL" KeyCode)" == "$KEY2" ]] || fail "2: UL key not updated"
[[ "$(reg_get "$P/user.reg" "$FM" KeyCode)" == "$KEY2" ]] || fail "2: FM key not updated"
[[ "$(reg_count "$P/user.reg" "$UL" KeyCode)" -eq 1 ]] || fail "2: duplicate UL keys"
[[ "$(reg_count "$P/user.reg" "$FM" KeyCode)" -eq 1 ]] || fail "2: duplicate FM keys"
pass "2: update in place, exactly one KeyCode per section"

# ---------------------------------------------------------------------------
# Test 3: idempotent second run leaves the registry untouched
# ---------------------------------------------------------------------------
before=$(cksum < "$P/user.reg")
out=$(run -p "$P" -k "$KEY2")
[[ "$(cksum < "$P/user.reg")" == "$before" ]] || fail "3: file rewritten on no-op run"
[[ "$out" == *"Nothing to do"* ]] || fail "3: no-op run did not report already registered"
pass "3: repeated run is a no-op"

# ---------------------------------------------------------------------------
# Test 4: --section futuremark writes only the legacy section
# ---------------------------------------------------------------------------
P="$TMP_DIR/t4"; new_prefix "$P"
run -p "$P" -k "$KEY1" --section futuremark >/dev/null
[[ "$(reg_get "$P/user.reg" "$FM" KeyCode)" == "$KEY1" ]] || fail "4: FM key missing"
[[ -z "$(reg_get "$P/user.reg" "$UL" KeyCode)" ]] || fail "4: UL section written despite --section futuremark"
pass "4: --section futuremark restricts writes"

# ---------------------------------------------------------------------------
# Test 5: --section ul writes only the modern section
# ---------------------------------------------------------------------------
P="$TMP_DIR/t5"; new_prefix "$P"
run -p "$P" -k "$KEY1" --section ul >/dev/null
[[ "$(reg_get "$P/user.reg" "$UL" KeyCode)" == "$KEY1" ]] || fail "5: UL key missing"
[[ -z "$(reg_get "$P/user.reg" "$FM" KeyCode)" ]] || fail "5: FM section written despite --section ul"
pass "5: --section ul restricts writes"

# ---------------------------------------------------------------------------
# Test 6: --dry-run never modifies the file
# ---------------------------------------------------------------------------
P="$TMP_DIR/t6"; new_prefix "$P"
before=$(cksum < "$P/user.reg")
out=$(run -p "$P" -k "$KEY1" --dry-run)
[[ "$(cksum < "$P/user.reg")" == "$before" ]] || fail "6: --dry-run modified the registry"
[[ "$out" == *"[dry-run]"* ]] || fail "6: --dry-run produced no plan output"
pass "6: --dry-run is read-only"

# ---------------------------------------------------------------------------
# Test 7: key via stdin (-k -)
# ---------------------------------------------------------------------------
P="$TMP_DIR/t7"; new_prefix "$P"
printf '%s\n' "$KEY1" | "$SETUP" -p "$P" -k - >/dev/null 2>&1
[[ "$(reg_get "$P/user.reg" "$UL" KeyCode)" == "$KEY1" ]] || fail "7: stdin key not applied"
pass "7: -k - reads the key from stdin"

# ---------------------------------------------------------------------------
# Test 8: keys with surrounding whitespace/CR are normalised
# ---------------------------------------------------------------------------
P="$TMP_DIR/t8"; new_prefix "$P"
run -p "$P" -k "  $KEY1  " >/dev/null
[[ "$(reg_get "$P/user.reg" "$UL" KeyCode)" == "$KEY1" ]] || fail "8: key not trimmed"
pass "8: whitespace around the key is stripped"

# ---------------------------------------------------------------------------
# Test 9: STEAM-ENTITLEMENT marker is rejected
# ---------------------------------------------------------------------------
P="$TMP_DIR/t9"; new_prefix "$P"
set +e; run -p "$P" -k "STEAM-ENTITLEMENT" >/dev/null; rc=$?; set -e
[[ $rc -eq 4 ]] || fail "9: expected exit 4 for STEAM-ENTITLEMENT, got $rc"
[[ -z "$(reg_get "$P/user.reg" "$UL" KeyCode)" ]] || fail "9: marker was written to the registry"
pass "9: STEAM-ENTITLEMENT rejected with exit 4"

# ---------------------------------------------------------------------------
# Test 10: DLC keys land in the UL section only
# ---------------------------------------------------------------------------
P="$TMP_DIR/t10"; new_prefix "$P"
run -p "$P" -k "$KEY1" --timespy-key "$SPY" --portroyal-key "$PR" >/dev/null
[[ "$(reg_get "$P/user.reg" "$UL" TimeSpyKeyCode)" == "$SPY" ]] || fail "10: TimeSpyKeyCode missing"
[[ "$(reg_get "$P/user.reg" "$UL" PortRoyalKeyCode)" == "$PR" ]] || fail "10: PortRoyalKeyCode missing"
[[ -z "$(reg_get "$P/user.reg" "$FM" TimeSpyKeyCode)" ]] || fail "10: TimeSpyKeyCode leaked into Futuremark"
pass "10: DLC keys written to the UL section only"

# ---------------------------------------------------------------------------
# Test 11: an empty Futuremark KeyCode cannot shadow a real UL key
# ---------------------------------------------------------------------------
P="$TMP_DIR/t11"; new_prefix "$P"
cat >> "$P/user.reg" <<EOF

[$UL] 1700000000
#time=6553f100
"KeyCode"="STEAM-ENTITLEMENT"

[$FM] 1700000001
#time=6553f101
"KeyCode"=""
EOF
out=$(run -p "$P" -k "$KEY1")
[[ "$(reg_get "$P/user.reg" "$UL" KeyCode)" == "$KEY1" ]] || fail "11: UL key not replaced"
[[ "$(reg_get "$P/user.reg" "$FM" KeyCode)" == "$KEY1" ]] || fail "11: empty FM KeyCode not filled"
pass "11: entitlement marker replaced, empty FM value filled"

# ---------------------------------------------------------------------------
# Test 12: --show-key reveals the key, default output does not
# ---------------------------------------------------------------------------
P="$TMP_DIR/t12"; new_prefix "$P"
out=$(run -p "$P" -k "$KEY1" --show-key)
[[ "$out" == *"$KEY1"* ]] || fail "12: --show-key did not print the key"
pass "12: --show-key unmasked output"

# ---------------------------------------------------------------------------
# Test 13: positional key and -a appid are still accepted
# ---------------------------------------------------------------------------
P="$TMP_DIR/t13"; new_prefix "$P"
run -p "$P" "$KEY1" >/dev/null
[[ "$(reg_get "$P/user.reg" "$UL" KeyCode)" == "$KEY1" ]] || fail "13: positional key not applied"
pass "13: positional CD_KEY argument works"

# ---------------------------------------------------------------------------
# Test 14: --section rejects invalid values
# ---------------------------------------------------------------------------
set +e
"$SETUP" -p "$P" -k "$KEY1" --section bogus >/dev/null 2>&1; rc=$?
set -e
[[ $rc -ne 0 ]] || fail "14: invalid --section accepted"
pass "14: invalid --section rejected"

# ---------------------------------------------------------------------------
# Test 15: -p accepts the compatdata dir (with pfx/) and a direct user.reg path
# ---------------------------------------------------------------------------
P="$TMP_DIR/t15"; new_prefix "$P/pfx"; mkdir -p "$P"
run -p "$P" -k "$KEY1" >/dev/null
[[ "$(reg_get "$P/pfx/user.reg" "$UL" KeyCode)" == "$KEY1" ]] || fail "15: pfx directory not resolved"
P2="$TMP_DIR/t15b"; new_prefix "$P2"
run -p "$P2/user.reg" -k "$KEY2" >/dev/null
[[ "$(reg_get "$P2/user.reg" "$UL" KeyCode)" == "$KEY2" ]] || fail "15: direct user.reg path not resolved"
pass "15: prefix path forms (dir, dir/pfx, user.reg) all work"

# ---------------------------------------------------------------------------
# Test 16: unrelated appid/prefix changes leave other sections untouched
# ---------------------------------------------------------------------------
P="$TMP_DIR/t16"; new_prefix "$P"
run -p "$P" -k "$KEY1" >/dev/null
grep -Fq '"d3dcompiler_43"="native,builtin"' "$P/user.reg" || fail "16: unrelated value lost"
grep -Fq '"USERNAME"="steamuser"' "$P/user.reg" || fail "16: unrelated section lost"
[[ "$(reg_count "$P/user.reg" 'Software\\Wine\\DllOverrides' KeyCode)" -eq 0 ]] || fail "16: key leaked into other section"
pass "16: unrelated registry content preserved"

echo "All tests passed successfully."
