#!/usr/bin/env bash
set -euo pipefail

# 3DMark Proton Registration & Runtime Fix
# Targets AppIDs:
#   223850 - 3DMark (Advanced Edition)
#   231350 - 3DMark Demo (always Basic Edition - no key needed)
#
# Modern 3DMark (UL) reads its paid key from:
#   [HKEY_CURRENT_USER\Software\UL\3DMark] "KeyCode" = "3DM-ICF-..."
# Older builds / some tests read:
#   [HKEY_CURRENT_USER\Software\Futuremark\3DMark] "KeyCode"
#
# Steam never writes these keys into Proton prefixes on Linux, so they must be
# injected manually. This script can pull the key straight from the Steam
# client (clipboard bridge) instead of asking you to copy/paste into regedit.

MAIN_APPID=223850
APP_IDS=(223850 231350)

SECTION_UL='Software\\UL\\3DMark'
SECTION_FM='Software\\Futuremark\\3DMark'

# Common Steam library installation roots for native and Flatpak packages
STEAM_ROOTS=(
  "${HOME}/.local/share/Steam"
  "${HOME}/.steam/steam"
  "${HOME}/.steam/root"
  "${HOME}/.steam/debian-installation"
  "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam"
  "${HOME}/.var/app/com.valvesoftware.Steam/.steam/steam"
)

# Display command-line usage and options
usage() {
  cat <<EOF
Usage: $0 [OPTIONS] [CD_KEY]

Options:
  -k, --key KEY         Registration key (e.g. 3DM-ICF-XXXX-XXXX-XXXX-XXXX)
                        Use "-" to read the key from stdin.
      --from-steam      Extract the key from the running Steam client:
                        opens Manage > CD keys and reads the key from the
                        clipboard once you click it. Falls back to local
                        Steam files if a key is already stored there.
      --clipboard       Read the key from the clipboard (no prompt).
      --wait SECONDS    How long --from-steam waits for the key (default 120).
      --open-cdkeys     Just open Steam's CD keys dialog for 3DMark and exit.
  -p, --prefix PATH     Explicit compatdata prefix path (contains pfx/)
  -a, --appid ID        Target AppID (default: auto-detect 223850 or 231350)
      --section WHICH   Registry section to write: ul, futuremark, or both
                        (default: both)
      --timespy-key K   Also write TimeSpyKeyCode (3DM-SPY-...), UL section
      --portroyal-key K Also write PortRoyalKeyCode (3DM-PR-...), UL section
      --show-key        Do not mask the key in output
      --dry-run         Show actions without modifying files
  -h, --help            Show this help

If no key is supplied the script:
  1. looks for a real key already present in Steam's local files/prefixes;
  2. otherwise uses a 3DM-... key currently on the clipboard;
  3. otherwise prompts interactively (TTY) or tells you how to extract it.
EOF
  exit 0
}

# CLI state
KEY=""
KEY_STDIN=0
PREFIX=""
TARGET_APPID=""
SECTION_MODE="both"
FROM_STEAM=0
READ_CLIPBOARD=0
WAIT_SECS=120
OPEN_CDKEYS_ONLY=0
TIMESPY_KEY=""
PORTROYAL_KEY=""
SHOW_KEY=0
DRY_RUN=0

# Abort when a value-taking option has no value
need_value() {
  [[ $# -ge 2 && -n "$2" ]] || { echo "Error: $1 requires a value" >&2; exit 1; }
}

# Parse options and flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    -k|--key)
      need_value "$@"
      if [[ "$2" == "-" ]]; then KEY_STDIN=1; else KEY="$2"; fi
      shift 2 ;;
    --from-steam) FROM_STEAM=1; shift ;;
    --clipboard) READ_CLIPBOARD=1; shift ;;
    --wait) need_value "$@"; WAIT_SECS="$2"; shift 2 ;;
    --open-cdkeys) OPEN_CDKEYS_ONLY=1; shift ;;
    -p|--prefix) need_value "$@"; PREFIX="$2"; shift 2 ;;
    -a|--appid) need_value "$@"; TARGET_APPID="$2"; shift 2 ;;
    --section) need_value "$@"; SECTION_MODE="$2"; shift 2 ;;
    --timespy-key) need_value "$@"; TIMESPY_KEY="$2"; shift 2 ;;
    --portroyal-key) need_value "$@"; PORTROYAL_KEY="$2"; shift 2 ;;
    --show-key) SHOW_KEY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) KEY="$1"; shift ;;
  esac
done

case "$SECTION_MODE" in
  ul|futuremark|both) ;;
  *) echo "Error: --section must be ul, futuremark, or both" >&2; exit 1 ;;
esac

# Trim whitespace/CR from a key and normalise case for 3DM keys
normalise_key() {
  local k
  k="$(printf '%s' "$1" | tr -d '[:space:]')"
  printf '%s' "$k"
}

# Mask a key for logs (never print the full key unless --show-key)
mask_key() {
  local k="$1"
  if [[ $SHOW_KEY -eq 1 ]]; then printf '%s' "$k"; return; fi
  if (( ${#k} <= 8 )); then printf '***'; else printf '%s…%s' "${k:0:4}" "${k: -4}"; fi
}

# Reject Steam markers/placeholders that are not a real registration key.
is_real_key() {
  local k="$1"
  [[ -n "$k" ]] || return 1
  case "$k" in
    *XXXX*|*xxxx*|*YOUR*|*your*|STEAM-ENTITLEMENT|CDKEY|KEYCODE) return 1 ;;
  esac
  [[ "$k" =~ ^3DM-[A-Za-z0-9]{2,4}(-[A-Za-z0-9]{4,6}){3,5}$ ]] && return 0
  [[ "$k" =~ ^[A-Za-z0-9]{4,6}(-[A-Za-z0-9]{4,6}){3,6}$ ]] && return 0
  return 1
}

# Extract all 3DM-* keys from arbitrary text (Steam dialogs, vdf files, ...)
extract_3dm_keys() {
  grep -oE '3DM-[A-Za-z0-9]{2,4}(-[A-Za-z0-9]{4,6}){3,5}' <<<"$1" 2>/dev/null || true
}

# Extract the primary Advanced key (skip DLC keys and placeholders)
extract_main_key() {
  local k
  while IFS= read -r k; do
    case "$k" in
      *-SPY-*|3DM-PR-*|*XXXX*|*xxxx*) continue ;;
    esac
    is_real_key "$k" && { printf '%s\n' "$k"; return 0; }
  done < <(extract_3dm_keys "$1")
  return 1
}

# ---------------------------------------------------------------------------
# Steam discovery helpers
# ---------------------------------------------------------------------------

# Resolve Steam roots plus any extra library paths declared in libraryfolders.vdf
steam_roots() {
  local root lib lf
  local -a roots=()
  for root in "${STEAM_ROOTS[@]}"; do
    [[ -d "$root" ]] && roots+=("$root")
  done
  for root in "${roots[@]}"; do
    for lf in "$root/steamapps/libraryfolders.vdf" "$root/config/libraryfolders.vdf"; do
      [[ -f "$lf" ]] || continue
      while IFS= read -r lib; do
        [[ -n "$lib" && -d "$lib" ]] && roots+=("$lib")
      done < <(awk -F'"' '/"path"/ {print $4}' "$lf" 2>/dev/null || true)
    done
  done
  printf '%s\n' "${roots[@]}" | sort -u
}

# Locate valid Wine pfx directories based on explicit path or Steam libraries
find_prefixes() {
  local found=()
  if [[ -n "$PREFIX" ]]; then
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
    local ids=("${APP_IDS[@]}")
    [[ -n "$TARGET_APPID" ]] && ids=("$TARGET_APPID")
    local root appid cand
    while IFS= read -r root; do
      for appid in "${ids[@]}"; do
        cand="$root/steamapps/compatdata/$appid/pfx"
        [[ -d "$cand" ]] && found+=("$(realpath "$cand")")
      done
    done < <(steam_roots)
  fi
  if (( ${#found[@]} == 0 )); then
    return 0
  fi
  printf '%s\n' "${found[@]}" | sort -u
}

# Read a value from a Wine user.reg section.
# Section/value names are passed through the environment because awk -v
# expands backslash escapes, which corrupts registry paths like Software\UL\3DMark.
read_reg_value() {
  local reg="$1" section="$2" name="$3"
  [[ -f "$reg" ]] || return 0
  SEC="$section" NM="$name" awk '
    /^\[/ {
      h=$0; sub(/^\[/,"",h); sub(/\].*$/,"",h)
      insec = (h == ENVIRON["SEC"])
      next
    }
    insec && index($0, "\"" ENVIRON["NM"] "\"=") == 1 {
      v = substr($0, length(ENVIRON["NM"]) + 4)
      sub(/^"/,"",v); sub(/"$/,"",v)
      print v
      exit
    }
  ' "$reg"
}

# Does the section already exist in the file?
has_section() {
  local reg="$1" section="$2"
  [[ -f "$reg" ]] || return 1
  SEC="$section" awk 'index($0, "[" ENVIRON["SEC"] "]") == 1 { found=1; exit } END { exit !found }' "$reg"
}

# Set (insert or replace) a string value inside a Wine user.reg section
set_reg_value() {
  local reg="$1" section="$2" name="$3" value="$4"
  local escaped entry

  escaped=$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  entry=$(printf '"%s"="%s"' "$name" "$escaped")

  if has_section "$reg" "$section"; then
    SEC="$section" NM="$name" ENTRY="$entry" awk '
      /^\[/ {
        # Leaving the target section without the value: insert it first
        if (insec && !done) { print ENVIRON["ENTRY"]; done=1 }
        h=$0; sub(/^\[/,"",h); sub(/\].*$/,"",h)
        insec = (h == ENVIRON["SEC"])
        print
        next
      }
      insec && index($0, "\"" ENVIRON["NM"] "\"=") == 1 {
        if (!done) { print ENVIRON["ENTRY"]; done=1 }
        next
      }
      { print }
      END { if (insec && !done) print ENVIRON["ENTRY"] }
    ' "$reg" > "${reg}.tmp" && mv "${reg}.tmp" "$reg"
  else
    local ts hex
    ts=$(date +%s)
    hex=$(printf '%x' "$ts")
    {
      printf '\n[%s] %d\n' "$section" "$ts"
      printf '#time=%s\n' "$hex"
      printf '%s\n' "$entry"
    } >> "$reg"
  fi
}

# Clipboard helpers (Wayland first, then X11)
read_clipboard() {
  if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-paste >/dev/null 2>&1; then
    wl-paste --no-newline 2>/dev/null || true
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard -o 2>/dev/null || true
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --output 2>/dev/null || true
  fi
}

# Open Steam's Manage > CD keys dialog for an app
open_cdkeys() {
  local appid="$1" launcher=""
  if command -v steam >/dev/null 2>&1; then
    launcher="steam"
  elif [[ -x "${HOME}/.local/share/Steam/steam.sh" ]]; then
    launcher="${HOME}/.local/share/Steam/steam.sh"
  elif command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
    launcher="flatpak run com.valvesoftware.Steam"
  elif command -v xdg-open >/dev/null 2>&1; then
    launcher="xdg-open"
  fi

  if [[ -z "$launcher" ]]; then
    echo "Warning: could not find a Steam launcher. Open Steam manually:" >&2
    echo "  Library -> 3DMark -> Manage -> CD keys" >&2
    return 1
  fi
  echo "Opening Steam CD keys dialog for AppID $appid..." >&2
  ( nohup $launcher "steam://cdkeys/$appid" >/dev/null 2>&1 & ) || true
}

# Poll the clipboard until a real 3DM- key appears
wait_for_clipboard_key() {
  local timeout="${1:-120}" start now k
  start=$(date +%s)
  while :; do
    k=$(extract_main_key "$(read_clipboard)" 2>/dev/null || true)
    if [[ -n "$k" ]]; then
      printf '%s\n' "$k"
      return 0
    fi
    now=$(date +%s)
    (( now - start >= timeout )) && return 1
    sleep 0.5
  done
}

# Search local Steam files and existing prefixes for a real 3DMark key
discover_local_key() {
  local root f k reg

  while IFS= read -r root; do
    for f in \
      "$root/registry.vdf" \
      "$root/config/config.vdf" \
      "$root/steamapps/common/3DMark/installscript.vdf" \
      "$root/steamapps/common/3DMark/installscript_si.vdf"; do
      [[ -f "$f" ]] || continue
      k=$(extract_main_key "$(cat "$f" 2>/dev/null)" 2>/dev/null || true)
      if [[ -n "$k" ]]; then printf '%s\n' "$k"; return 0; fi
    done
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      k=$(extract_main_key "$(cat "$f" 2>/dev/null)" 2>/dev/null || true)
      if [[ -n "$k" ]]; then printf '%s\n' "$k"; return 0; fi
    done < <(find "$root/userdata" -maxdepth 4 -path '*/config/*' -name '*.vdf' -type f 2>/dev/null || true)
  done < <(steam_roots)

  # Existing Proton prefixes (including a previous run of this script)
  local p
  for p in "${DETECTED[@]:-}"; do
    reg="$p/user.reg"
    [[ -f "$reg" ]] || continue
    for k in "$(read_reg_value "$reg" "$SECTION_UL" KeyCode)" \
             "$(read_reg_value "$reg" "$SECTION_FM" KeyCode)"; do
      if is_real_key "$k"; then printf '%s\n' "$k"; return 0; fi
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

mapfile -t DETECTED < <(find_prefixes)

if [[ $OPEN_CDKEYS_ONLY -eq 1 ]]; then
  open_cdkeys "$MAIN_APPID"
  exit 0
fi

if [[ ${#DETECTED[@]} -eq 0 ]]; then
  echo "Error: No 3DMark Proton prefix detected." >&2
  echo "Launch 3DMark at least once in Steam to generate compatdata." >&2
  exit 2
fi

echo "Detected 3DMark prefix(es):"
for p in "${DETECTED[@]}"; do
  echo "  - $p"
done

# Read stdin key if requested
if [[ $KEY_STDIN -eq 1 ]]; then
  IFS= read -r KEY || true
fi

# Report keys that are already present (per section, so the empty
# Futuremark KeyCode can never shadow a real UL key)
for p in "${DETECTED[@]}"; do
  reg="$p/user.reg"
  [[ -f "$reg" ]] || continue
  for section in "$SECTION_UL" "$SECTION_FM"; do
    cur=$(read_reg_value "$reg" "$section" KeyCode)
    [[ -n "$cur" ]] || continue
    if is_real_key "$cur"; then
      echo "Found existing key in $section: $(mask_key "$cur")"
    elif [[ "$cur" == "STEAM-ENTITLEMENT" ]]; then
      echo "Found Steam entitlement marker in $section (not a paid key)"
    fi
  done
done

# Resolve the key
if [[ -n "$KEY" ]]; then
  KEY=$(normalise_key "$KEY")
elif [[ $READ_CLIPBOARD -eq 1 ]]; then
  KEY=$(extract_main_key "$(read_clipboard)" 2>/dev/null || true)
  [[ -n "$KEY" ]] || { echo "Error: no 3DM-... key found on the clipboard." >&2; exit 4; }
  echo "Using key from clipboard: $(mask_key "$KEY")"
elif [[ $FROM_STEAM -eq 1 ]]; then
  KEY=$(discover_local_key 2>/dev/null || true)
  if [[ -n "$KEY" ]]; then
    echo "Found key in local Steam data: $(mask_key "$KEY")"
  else
    echo "Steam does not expose CD keys to scripts, so this uses the client UI:"
    echo "  1. The CD keys dialog will open."
    echo "  2. Click the 3DMark Advanced key to copy it."
    echo "  3. The script picks it up from the clipboard automatically."
    open_cdkeys "$MAIN_APPID" || true
    KEY=$(wait_for_clipboard_key "$WAIT_SECS" 2>/dev/null || true)
    if [[ -z "$KEY" ]]; then
      echo "Error: timed out after ${WAIT_SECS}s waiting for a key on the clipboard." >&2
      echo "Copy it from Steam (Manage -> CD keys) and rerun with --clipboard." >&2
      exit 4
    fi
    echo "Read key from clipboard: $(mask_key "$KEY")"
  fi
else
  # Best-effort: local Steam files -> clipboard -> interactive prompt
  KEY=$(discover_local_key 2>/dev/null || true)
  if [[ -n "$KEY" ]]; then
    echo "Found key in local Steam data: $(mask_key "$KEY")"
  else
    clip_key=$(extract_main_key "$(read_clipboard)" 2>/dev/null || true)
    if [[ -n "$clip_key" ]]; then
      KEY="$clip_key"
      echo "Using key from clipboard: $(mask_key "$KEY")"
    fi
  fi
  if [[ -z "$KEY" && -t 0 ]]; then
    echo "Steam does not expose CD keys to scripts."
    echo "Get it from: 3DMark -> Manage -> CD keys (or rerun with --from-steam)."
    read -r -p "Enter 3DMark CD/Registration Key (or press enter to skip): " input_key || true
    KEY=$(normalise_key "${input_key:-}")
  fi
fi

# Nothing to do if a real key is already registered and no new key was given
if [[ -z "$KEY" ]]; then
  existing=""
  for p in "${DETECTED[@]}"; do
    reg="$p/user.reg"
    [[ -f "$reg" ]] || continue
    existing=$(read_reg_value "$reg" "$SECTION_UL" KeyCode)
    is_real_key "$existing" && break
    existing=$(read_reg_value "$reg" "$SECTION_FM" KeyCode)
    is_real_key "$existing" && break
    existing=""
  done
  if [[ -n "$existing" ]]; then
    echo "3DMark is already registered (KeyCode $(mask_key "$existing")). Nothing to do."
    exit 0
  fi
  echo "No key provided. Skipping registry key registration."
  exit 0
fi

# Validate the key
if [[ "$KEY" == "STEAM-ENTITLEMENT" ]]; then
  echo "Error: 'STEAM-ENTITLEMENT' is a Steam marker, not a paid registration key." >&2
  exit 4
fi
if ! is_real_key "$KEY"; then
  echo "Warning: '$KEY' does not look like a 3DMark key (expected 3DM-...). Continuing anyway." >&2
fi
TIMESPY_KEY=$(normalise_key "$TIMESPY_KEY")
PORTROYAL_KEY=$(normalise_key "$PORTROYAL_KEY")

# Which sections to write
targets=()
case "$SECTION_MODE" in
  ul) targets=("$SECTION_UL") ;;
  futuremark) targets=("$SECTION_FM") ;;
  both) targets=("$SECTION_UL" "$SECTION_FM") ;;
esac

# Apply the key
for p in "${DETECTED[@]}"; do
  reg="$p/user.reg"
  if [[ ! -f "$reg" ]]; then
    echo "Warning: $reg missing, skipping." >&2
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    for section in "${targets[@]}"; do
      echo "[dry-run] Would write KeyCode=$(mask_key "$KEY") to [$section] in $reg"
    done
    [[ -n "$TIMESPY_KEY" ]] && echo "[dry-run] Would write TimeSpyKeyCode=$(mask_key "$TIMESPY_KEY")"
    [[ -n "$PORTROYAL_KEY" ]] && echo "[dry-run] Would write PortRoyalKeyCode=$(mask_key "$PORTROYAL_KEY")"
    continue
  fi

  # Skip files that already hold exactly these values (keeps mtime intact)
  already=1
  for section in "${targets[@]}"; do
    if [[ "$(read_reg_value "$reg" "$section" KeyCode)" != "$KEY" ]]; then
      already=0
      break
    fi
    if [[ "$section" == "$SECTION_UL" ]]; then
      if [[ -n "$TIMESPY_KEY" && "$(read_reg_value "$reg" "$section" TimeSpyKeyCode)" != "$TIMESPY_KEY" ]]; then
        already=0
        break
      fi
      if [[ -n "$PORTROYAL_KEY" && "$(read_reg_value "$reg" "$section" PortRoyalKeyCode)" != "$PORTROYAL_KEY" ]]; then
        already=0
        break
      fi
    fi
  done
  if [[ $already -eq 1 ]]; then
    echo "3DMark is already registered in $reg (KeyCode $(mask_key "$KEY")). Nothing to do."
    continue
  fi

  # Create safety backup before editing (keep the original once)
  [[ -f "${reg}.bak" ]] || cp -p "$reg" "${reg}.bak"

  for section in "${targets[@]}"; do
    echo "Applying KeyCode to [$section] in: $reg"
    set_reg_value "$reg" "$section" "KeyCode" "$KEY"
    if [[ "$section" == "$SECTION_UL" ]]; then
      [[ -n "$TIMESPY_KEY" ]] && set_reg_value "$reg" "$section" "TimeSpyKeyCode" "$TIMESPY_KEY"
      [[ -n "$PORTROYAL_KEY" ]] && set_reg_value "$reg" "$section" "PortRoyalKeyCode" "$PORTROYAL_KEY"
    fi
  done

  # Verify every write, per section
  ok=1
  for section in "${targets[@]}"; do
    got=$(read_reg_value "$reg" "$section" KeyCode)
    if [[ "$got" != "$KEY" ]]; then
      echo "Error: verification failed for [$section] in $reg" >&2
      ok=0
    fi
  done
  if [[ $ok -eq 1 ]]; then
    echo "Successfully wrote KeyCode ($(mask_key "$KEY")) to $reg"
  else
    exit 3
  fi
done

# Advisory notices for known 3DMark on Proton issues
cat <<'EOF'

[Configuration Notice]
1. If 3DMark UI crashes on launch (black window / CEF fault), add launch options in Steam:
   --use-gl=osmesa
2. If benchmarks fail to compile shaders or throw missing DirectX DLL errors, install runtimes:
   protontricks 223850 d3dcompiler_43 d3dcompiler_47
3. Restart 3DMark after registering. The paid key must be visible under
   HKCU\Software\UL\3DMark -> KeyCode (3DM-ICF-...).
EOF
