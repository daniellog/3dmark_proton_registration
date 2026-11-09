#!/usr/bin/env bash
#
# patch_3dmark_compat.sh - make 3DMark run Time Spy / Night Raid under Proton.
#
# UL's Futuremark SystemInfo (FMSIScan.exe) never writes the
# <Processor_Instruction_Sets> block when it runs under Wine/Proton, so the
# launcher sees a CPU with zero instruction sets and blocks every test that
# requires SSSE3 / SSE4.1 (Time Spy, Night Raid, several feature tests) with
# "Your CPU does not support SSSE 3".
#
# The CPU really does support SSSE3; only the SystemInfo *report* is broken.
# This script neutralises the single launcher check that turns that missing
# report into a blocking problem:
#
#   com/futuremark/choros/service/ProductStateServiceImpl.class
#     checkCpusForInstructionsSetRequirement(...)
#
# The method body is replaced with a plain `return`. Nothing else in the jar is
# touched, and the pristine jar is kept as choros.jar.orig so --revert always
# works. Verify the game in Steam after a game update, then re-apply.
#
# If 3DMark is not installed at all, --install asks the Steam client to download
# AppID 223850 and waits for it to finish before patching.
#
# Usage:
#   ./patch_3dmark_compat.sh              # patch (idempotent)
#   ./patch_3dmark_compat.sh --install    # install via Steam if missing, then patch
#   ./patch_3dmark_compat.sh --revert     # restore pristine jar
#   ./patch_3dmark_compat.sh --dry-run    # report only
#   ./patch_3dmark_compat.sh -g /path/to/3DMark
#
set -u

MAIN_APPID=223850

GAME_DIR=""
MODE="apply"
DRY=""
QUIET=""
INSTALL=0
INSTALL_ONLY=0
CHECK=0
INSTALL_TIMEOUT=3600
WAIT_INSTALL=1

usage() {
  cat <<'EOF'
Usage: patch_3dmark_compat.sh [OPTIONS]

Options:
  -g, --game-dir DIR     3DMark install directory (auto-detected by default)
      --install          If 3DMark is missing, make Steam download AppID 223850
                         and wait for it to finish before patching
      --check            Exit 0 if 3DMark is installed, 3 otherwise (silent)
      --install-only     Only perform the install check (do not patch)
      --install-timeout S  Give up waiting for the Steam download after S
                         seconds (default: 3600)
      --no-wait          Start the Steam download and exit immediately
      --revert           Restore the pristine choros.jar from choros.jar.orig
      --dry-run          Show what would happen, change nothing
  -q, --quiet            Only print errors
  -h, --help             Show this help

Exit codes:
  0  success / already in the requested state
  2  bad usage
  3  3DMark installation not found (pass --install to download it)
  4  python3 unavailable
  5  Java class patch failed
  6  Steam client not usable / install timed out
EOF
}

log() { [ -n "$QUIET" ] || printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; }
need_value() { [ $# -ge 2 ] && [ -n "$2" ] || { err "$1 needs a value"; exit 2; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--game-dir) need_value "$@"; GAME_DIR="$2"; shift 2 ;;
    --install) INSTALL=1; shift ;;
    --check|--status) CHECK=1; shift ;;
    --install-only) INSTALL=1; INSTALL_ONLY=1; shift ;;
    --install-timeout) need_value "$@"; INSTALL_TIMEOUT="$2"; shift 2 ;;
    --no-wait) WAIT_INSTALL=0; shift ;;
    --revert) MODE="revert"; shift ;;
    --dry-run) DRY=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "unknown option: $1"; usage >&2; exit 2 ;;
  esac
done
case "$INSTALL_TIMEOUT" in
  ''|*[!0-9]*) err "--install-timeout must be a number of seconds"; exit 2 ;;
esac

if [ -n "$GAME_DIR" ] && [ ! -f "$GAME_DIR/bin/x64/choros.jar" ]; then
  err "$GAME_DIR does not look like a 3DMark install (missing bin/x64/choros.jar)"
  exit 3
fi

# ---------------------------------------------------------------------------
# Steam library discovery (native, Flatpak, extra libraryfolders.vdf entries)
# ---------------------------------------------------------------------------
steam_roots() {
  local r
  # Explicit override (used by tests and non-standard setups)
  if [ -n "${DANLAN_3DMARK_STEAM_ROOTS:-}" ]; then
    printf '%s\n' "$DANLAN_3DMARK_STEAM_ROOTS" | tr ':' '\n' | while IFS= read -r r; do
      [ -n "$r" ] && [ -d "$r" ] && printf '%s\n' "$r"
    done
    return 0
  fi
  for r in \
    "$HOME/.local/share/Steam" \
    "$HOME/.steam/steam" \
    "$HOME/.steam/root" \
    "$HOME/.steam/debian-installation" \
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
    "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam"
  do
    [ -d "$r" ] && printf '%s\n' "$r"
  done
}

steam_libraries() {
  local root vdf p
  while IFS= read -r root; do
    printf '%s\n' "$root"
    vdf="$root/steamapps/libraryfolders.vdf"
    [ -f "$vdf" ] || continue
    while IFS= read -r p; do
      [ -n "$p" ] && printf '%s\n' "$p"
    done < <(grep -oE '"path"[[:space:]]+"[^"]+"' "$vdf" 2>/dev/null \
              | sed -E 's/.*"([^"]+)"$/\1/')
  done < <(steam_roots)
  [ -n "${DANLAN_3DMARK_STEAM_ROOTS:-}" ] && return 0
  for p in /mnt/*/Steam /mnt/*/steamapps /media/*/Steam /media/*/steamapps; do
    [ -d "$p" ] && printf '%s\n' "$p"
  done
}

find_game_dir() {
  local lib
  if [ -n "$GAME_DIR" ]; then
    [ -f "$GAME_DIR/bin/x64/choros.jar" ] || return 1
    printf '%s\n' "$GAME_DIR"
    return 0
  fi
  while IFS= read -r lib; do
    if [ -f "$lib/steamapps/common/3DMark/bin/x64/choros.jar" ]; then
      printf '%s\n' "$lib/steamapps/common/3DMark"
      return 0
    fi
    if [ -f "$lib/common/3DMark/bin/x64/choros.jar" ]; then
      printf '%s\n' "$lib/common/3DMark"
      return 0
    fi
  done < <(steam_libraries)
  return 1
}

# ---------------------------------------------------------------------------
# Steam install handling
# ---------------------------------------------------------------------------
steam_how() {
  if command -v steam >/dev/null 2>&1; then printf 'steam\n'; return 0; fi
  if command -v flatpak >/dev/null 2>&1 \
     && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
    printf 'flatpak\n'; return 0
  fi
  if command -v xdg-open >/dev/null 2>&1; then printf 'xdg-open\n'; return 0; fi
  return 1
}

trigger_install() {
  case "$1" in
    steam) ( nohup steam "steam://install/$MAIN_APPID" >/dev/null 2>&1 & ) ;;
    flatpak) ( nohup flatpak run com.valvesoftware.Steam "steam://install/$MAIN_APPID" >/dev/null 2>&1 & ) ;;
    xdg-open) ( nohup xdg-open "steam://install/$MAIN_APPID" >/dev/null 2>&1 & ) ;;
  esac
  sleep 1
}

downloaded_size() {
  local d
  for d in "$HOME/.local/share/Steam/steamapps/downloading/$MAIN_APPID" \
           "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/downloading/$MAIN_APPID"; do
    [ -d "$d" ] && { du -sh "$d" 2>/dev/null | cut -f1; return 0; }
  done
  return 1
}

wait_for_install() {
  local timeout="$1" start now last size
  start=$(date +%s)
  last=$start
  while :; do
    if find_game_dir >/dev/null; then return 0; fi
    now=$(date +%s)
    if [ $((now - start)) -ge "$timeout" ]; then return 1; fi
    if [ $((now - last)) -ge 30 ]; then
      size="$(downloaded_size || true)"
      log "  ... downloading 3DMark${size:+ ($size)}"
      last=$now
    fi
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# Locate (or install) the game
# ---------------------------------------------------------------------------
if ! GAME_DIR="$(find_game_dir)"; then
  [ "$CHECK" -eq 1 ] && exit 3
  if [ "$INSTALL" -eq 0 ]; then
    err "3DMark installation not found"
    err "pass -g /path/to/3DMark, or --install to download AppID $MAIN_APPID via Steam"
    exit 3
  fi
  if ! how="$(steam_how)"; then
    err "no Steam client found (steam, Flatpak Steam, or xdg-open)"
    exit 6
  fi
  log "3DMark (AppID $MAIN_APPID) is not installed - asking Steam to download it"
  if [ -n "$DRY" ]; then
    log "[dry-run] would launch: $how steam://install/$MAIN_APPID"
    log "[dry-run] would wait up to ${INSTALL_TIMEOUT}s for the download"
    exit 0
  fi
  trigger_install "$how"
  if [ "$WAIT_INSTALL" -eq 0 ]; then
    log "Steam download started - rerun this script when it finishes"
    exit 0
  fi
  log "Waiting up to ${INSTALL_TIMEOUT}s for the download to finish..."
  if ! wait_for_install "$INSTALL_TIMEOUT"; then
    err "timed out after ${INSTALL_TIMEOUT}s waiting for 3DMark to install"
    err "the download may still be running in Steam; rerun later or raise --install-timeout"
    exit 6
  fi
  GAME_DIR="$(find_game_dir)"
  log "Installed: $GAME_DIR"
fi

log "3DMark: $GAME_DIR"

if [ "$CHECK" -eq 1 ]; then
  exit 0
fi

if [ "$INSTALL_ONLY" -eq 1 ]; then
  log "3DMark is installed"
  exit 0
fi

BIN_DIR="$GAME_DIR/bin/x64"
JAR="$BIN_DIR/choros.jar"
ORIG="$BIN_DIR/choros.jar.orig"

# ---------------------------------------------------------------------------
# Revert
# ---------------------------------------------------------------------------
if [ "$MODE" = "revert" ]; then
  if [ ! -f "$ORIG" ]; then
    err "no pristine backup at $ORIG - nothing to revert"
    exit 5
  fi
  if cmp -s "$ORIG" "$JAR"; then
    log "Already pristine (choros.jar == choros.jar.orig)"
    exit 0
  fi
  if [ -n "$DRY" ]; then
    log "[dry-run] would restore choros.jar from choros.jar.orig"
    exit 0
  fi
  cp -f "$ORIG" "$JAR" || { err "could not restore $JAR"; exit 5; }
  log "Restored pristine choros.jar"
  exit 0
fi

command -v python3 >/dev/null 2>&1 || { err "python3 is required"; exit 4; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/3dmarkpatch.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/patch_choros.py" <<'PYEOF'
import struct
import sys
import warnings
import zipfile

TARGET_CLASS = "com/futuremark/choros/service/ProductStateServiceImpl.class"
TARGET_METHOD = "checkCpusForInstructionsSetRequirement"
TARGET_DESC = ("(Lcom/google/common/collect/ImmutableList$Builder;"
               "Lcom/futuremark/izzy/results/systeminfo/SystemInfo;"
               "Lcom/futuremark/izzy/results/systeminfo/InstructionSet;)V")

CP_FIXED = {3: 4, 4: 4, 8: 2, 9: 4, 10: 4, 11: 4, 12: 4, 7: 2,
            15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}


def u2(b, o):
    return struct.unpack_from(">H", b, o)[0], o + 2


def u4(b, o):
    return struct.unpack_from(">I", b, o)[0], o + 4


def read_pool(b):
    """Return ({index: utf8}, offset_after_pool) for a class file."""
    o = 4                      # magic
    _, o = u2(b, o)            # minor
    _, o = u2(b, o)            # major
    count, o = u2(b, o)
    strings = {}
    i = 1
    while i < count:
        tag = b[o]
        o += 1
        if tag == 1:                       # CONSTANT_Utf8
            ln, o = u2(b, o)
            strings[i] = b[o:o + ln].decode("utf-8", "replace")
            o += ln
        elif tag in (5, 6):                # Long / Double take two slots
            o += 8
            i += 1
        else:
            o += CP_FIXED[tag]
        i += 1
    return strings, o


def skip_attributes(b, o):
    n, o = u2(b, o)
    for _ in range(n):
        _, o = u2(b, o)
        ln, o = u4(b, o)
        o += ln
    return o


def find_code_attr(b, method_start, strings):
    o = method_start + 6                       # access, name, descriptor
    n, o = u2(b, o)
    for _ in range(n):
        name_idx, o = u2(b, o)
        len_off = o
        ln, o = u4(b, o)
        if strings.get(name_idx) == "Code":
            return len_off, o, ln
        o += ln
    return None


def patch_class(data):
    strings, o = read_pool(data)
    o += 6                                     # access, this, super
    n, o = u2(data, o)
    o += 2 * n                                 # interfaces
    n, o = u2(data, o)                         # fields
    for _ in range(n):
        o += 6
        o = skip_attributes(data, o)
    n, o = u2(data, o)                         # methods
    for _ in range(n):
        start = o
        _, o = u2(data, o)
        name_idx, o = u2(data, o)
        desc_idx, o = u2(data, o)
        if (strings.get(name_idx) == TARGET_METHOD
                and strings.get(desc_idx) == TARGET_DESC):
            hit = find_code_attr(data, start, strings)
            if hit is None:
                raise SystemExit("target method has no Code attribute")
            len_off, body_off, old_len = hit
            max_locals = struct.unpack_from(">H", data, body_off + 2)[0]
            body = struct.pack(">HHI", 0, max_locals, 1) + b"\xb1" + b"\x00\x00\x00\x00"
            return (bytes(data[:len_off]) + struct.pack(">I", len(body))
                    + body + data[body_off + old_len:])
        o = start + 6
        o = skip_attributes(data, o)
    raise SystemExit("target method not found (3DMark version changed?)")


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with zipfile.ZipFile(src) as zin:
            entries = [(i, zin.read(i.filename)) for i in zin.infolist()]
        payload = {info.filename: data for info, data in entries}
        if TARGET_CLASS not in payload:
            raise SystemExit(f"{TARGET_CLASS} not present in {src}")
        patched = patch_class(payload[TARGET_CLASS])
        if patched == payload[TARGET_CLASS]:
            raise SystemExit("patch produced no change")
        with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
            for info, data in entries:
                if info.filename == TARGET_CLASS:
                    data = patched
                zout.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED)


if __name__ == "__main__":
    main()
PYEOF

# ---------------------------------------------------------------------------
# Ensure a pristine backup exists, then build the patched jar from it
# ---------------------------------------------------------------------------
if [ ! -f "$ORIG" ]; then
  if [ -n "$DRY" ]; then
    log "[dry-run] would back up choros.jar -> choros.jar.orig"
    ORIG="$JAR"
  else
    cp -p "$JAR" "$ORIG" || { err "could not create $ORIG"; exit 5; }
    log "Backed up pristine launcher: $ORIG"
  fi
fi

python3 "$WORK/patch_choros.py" "$ORIG" "$WORK/choros.jar" || {
  err "failed to patch the launcher class"
  exit 5
}

if cmp -s "$WORK/choros.jar" "$JAR"; then
  log "Already patched - nothing to do"
  exit 0
fi

if [ -n "$DRY" ]; then
  log "[dry-run] would install patched choros.jar (SSSE3 check disabled)"
  exit 0
fi

cp -f "$WORK/choros.jar" "$JAR" || { err "could not write $JAR"; exit 5; }
log "Patched launcher installed: Time Spy / Night Raid SSSE3 gate disabled"

if pgrep -f 'bin/x64/3DMark\.exe' >/dev/null 2>&1; then
  log "3DMark is running - restart it for the change to take effect"
fi
log "Revert any time with: $0 --revert"
