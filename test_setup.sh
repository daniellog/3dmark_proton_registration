#!/usr/bin/env bash
set -euo pipefail

TMP_DIR=$(mktemp -d /tmp/3dmark_test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

REG_FILE="$TMP_DIR/user.reg"

cat <<'EOF' > "$REG_FILE"
WINE REGISTRY Version 2
;; All keys relative to \\User\\S-1-5-21-0-0-0-1000

[Software\\Wine\\DllOverrides] 1793687163
#time=1dd6b5c33adccb0
"d3dcompiler_43"="native,builtin"

[Volatile Environment] 1794254365
#time=1dd7084d26ca970
"USERNAME"="steamuser"
EOF

# Test 1: Insert key into new section
/home/daniellog/Projects/3dmark_proton_registration/setup_3dmark.sh -p "$TMP_DIR" -k "TEST-KEY-1111-2222" > /dev/null
grep -Fq '[Software\\Futuremark\\3DMark]' "$REG_FILE" || { echo "Test 1 failed: section missing"; exit 1; }
grep -Fq '"KeyCode"="TEST-KEY-1111-2222"' "$REG_FILE" || { echo "Test 1 failed: key missing"; exit 1; }

# Test 2: Update existing key
/home/daniellog/Projects/3dmark_proton_registration/setup_3dmark.sh -p "$TMP_DIR" -k "TEST-KEY-3333-4444" > /dev/null
grep -Fq '"KeyCode"="TEST-KEY-3333-4444"' "$REG_FILE" || { echo "Test 2 failed: key update missing"; exit 1; }
[[ $(grep -c '^"KeyCode"=' "$REG_FILE") -eq 1 ]] || { echo "Test 2 failed: duplicate keys found"; exit 1; }

echo "All tests passed successfully."
