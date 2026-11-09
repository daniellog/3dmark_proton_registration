#!/usr/bin/env bash
set -euo pipefail

# 3DMark Proton Registration & Runtime Fix
# Targets AppIDs:
#   223850 - 3DMark (Advanced Edition)
#   231350 - 3DMark Demo

APP_IDS=(223850 231350)

# Common Steam library installation roots for native and Flatpak packages
STEAM_ROOTS=(
  "${HOME}/.local/share/Steam"
  "${HOME}/.steam/steam"
  "${HOME}/.steam/root"
  "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam"
  "${HOME}/.var/app/com.valvesoftware.Steam/.steam/steam"
)

# Display command-line usage and options
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [CD_KEY]

Options:
  -k, --key KEY       Registration key (e.g. 3DM-ADV-XXXXX-XXXXX-XXXXX-XXXXX)
  -p, --prefix PATH   Explicit compatdata prefix path (contains pfx/)
  -a, --appid ID      Target AppID (default: auto-detect 223850 or 231350)
  --dry-run           Show actions without modifying files
  -h, --help          Show this help

If KEY is omitted, script prompts interactively or checks KeyCode in registry.
EOF
  exit 1
}

# CLI Argument state
KEY=""
PREFIX=""
TARGET_APPID=""
DRY_RUN=0

# Parse options and flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--key) KEY="$2"; shift 2 ;;
    -p|--prefix) PREFIX="$2"; shift 2 ;;
    -a|--appid) TARGET_APPID="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) KEY="$1"; shift ;;
  esac
done

# Locate valid Wine pfx directories based on explicit path or standard Steam locations
find_prefixes() {
  local found=()
  if [[ -n "$PREFIX" ]]; then
    # User provided an explicit prefix or direct registry path
    if [[ -d "$PREFIX/pfx" ]]; then
      found+=("$(realpath "$PREFIX/pfx")")
    elif [[ -f "$PREFIX/user.reg" ]]; then
      found+=("$(realpath "$PREFIX")")
    elif [[ -f "$PREFIX" && "$(basename "$PREFIX")" == "user.reg" ]]; then
      found+=("$(realpath "$(dirname "$PREFIX")")")
    else
      echo "Error: Invalid prefix path '$PREFIX'" >&2
      exit 1
    fi
  else
    # Auto-detect across standard native and flatpak Steam roots
    local ids=("${APP_IDS[@]}")
    [[ -n "$TARGET_APPID" ]] && ids=("$TARGET_APPID")
    for root in "${STEAM_ROOTS[@]}"; do
      for appid in "${ids[@]}"; do
        local cand="$root/steamapps/compatdata/$appid/pfx"
        if [[ -d "$cand" ]]; then
          found+=("$(realpath "$cand")")
        fi
      done
    done
  fi
  # Deduplicate symlinked paths (e.g. ~/.steam/steam -> ~/.local/share/Steam)
  printf '%s\n' "${found[@]}" | sort -u
}

# Safely inject or update KeyCode in user.reg while preserving existing entries
write_key_user_reg() {
  local reg_file="$1"
  local key="$2"
  # Escape backslashes and double quotes for Wine registry format
  local escaped_key
  escaped_key=$(printf '%s' "$key" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  local timestamp
  timestamp=$(date +%s)

  if grep -q '^\[Software\\\\Futuremark\\\\3DMark\]' "$reg_file" 2>/dev/null; then
    # Section exists: update existing KeyCode or append it into the section block
    awk -v key="$escaped_key" '
      BEGIN { in_section=0; key_written=0 }
      /^\[Software\\\\Futuremark\\\\3DMark\]/ {
        in_section=1
        print
        next
      }
      in_section && /^\[/ {
        # Leaving target section without encountering KeyCode; insert it before next section
        if (!key_written) {
          print "\"KeyCode\"=\"" key "\""
          key_written=1
        }
        in_section=0
      }
      in_section && /^"KeyCode"=/ {
        # Replace existing KeyCode
        print "\"KeyCode\"=\"" key "\""
        key_written=1
        next
      }
      { print }
      END {
        # If target section was the last section in the file
        if (in_section && !key_written) {
          print "\"KeyCode\"=\"" key "\""
        }
      }
    ' "$reg_file" > "${reg_file}.tmp" && mv "${reg_file}.tmp" "$reg_file"
  else
    # Section does not exist: append new section header and KeyCode to file end
    printf '\n[Software\\\\Futuremark\\\\3DMark] %d\n"KeyCode"="%s"\n' "$timestamp" "$escaped_key" >> "$reg_file"
  fi
}

# Resolve active prefixes
mapfile -t DETECTED < <(find_prefixes)

if [[ ${#DETECTED[@]} -eq 0 ]]; then
  echo "Error: No 3DMark Proton prefix detected." >&2
  echo "Launch 3DMark at least once in Steam to generate compatdata." >&2
  exit 2
fi

echo "Detected 3DMark prefix(es):"
for p in "${DETECTED[@]}"; do
  echo "  - $p"
done

# If key was not passed via CLI, inspect prefix for an existing key or prompt interactively
if [[ -z "$KEY" ]]; then
  for p in "${DETECTED[@]}"; do
    if [[ -f "$p/user.reg" ]]; then
      current=$(awk -F'=' '/^"KeyCode"=/ { gsub(/"/, "", $2); print $2 }' "$p/user.reg" || true)
      if [[ -n "$current" ]]; then
        echo "Found existing KeyCode in $p: $current"
      fi
    fi
  done
  if [[ -t 0 ]]; then
    read -r -p "Enter 3DMark CD/Registration Key (or press enter to skip): " input_key || true
    KEY="${input_key:-}"
  fi
fi

# Apply registration key if provided
if [[ -n "$KEY" ]]; then
  # Strip whitespace and carriage returns from key string
  KEY="$(echo -e "${KEY}" | tr -d '[:space:]')"
  for p in "${DETECTED[@]}"; do
    reg="$p/user.reg"
    if [[ ! -f "$reg" ]]; then
      echo "Warning: $reg missing, skipping." >&2
      continue
    fi
    echo "Applying KeyCode to: $reg"
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[dry-run] Would write KeyCode to $reg"
      continue
    fi
    # Create safety backup before editing
    [[ -f "${reg}.bak" ]] || cp -p "$reg" "${reg}.bak"
    write_key_user_reg "$reg" "$KEY"

    # Verify write
    if grep -q "^\"KeyCode\"=\"${KEY}\"" "$reg"; then
      echo "Successfully wrote KeyCode to $reg"
    else
      echo "Error: Failed verifying KeyCode in $reg" >&2
      exit 3
    fi
  done
else
  echo "No key provided. Skipping registry key registration."
fi

# Advisory notices for known 3DMark on Proton issues
cat <<'EOF'

[Configuration Notice]
1. If 3DMark UI crashes on launch (black window / CEF fault), add launch options in Steam:
   --use-gl=osmesa
2. If benchmarks fail to compile shaders or throw missing DirectX DLL errors, install runtimes:
   protontricks 223850 d3dcompiler_43 d3dcompiler_47
EOF
