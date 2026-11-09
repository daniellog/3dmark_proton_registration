# 3DMark Proton Registration & Configuration

Automated CLI tooling to run paid 3DMark (Steam AppID `223850`) properly under Proton on
Linux: install the game through Steam if needed, inject the paid CD/registration key into the
Wine prefix registry, and patch the launcher so Time Spy / Night Raid stop claiming the CPU
lacks SSSE3.

## Quick start

```bash
# Everything in one go: download 3DMark if missing, register the key, patch the launcher
./setup_3dmark.sh --install --from-steam

# Already installed and just want the key + Time Spy/Night Raid unlock
./setup_3dmark.sh --from-steam

# Standalone launcher patch (idempotent, revertible)
./patch_3dmark_compat.sh
```

Launch 3DMark once after a fresh install so Proton creates the prefix, then run the script
again; it detects the prefix automatically.

---

## The Problem
On Windows, Steam automatically injects CD keys into the Windows registry using `LegacyKeyRegistrationMethod = registry`.
On Linux, the Steam client does not process this instruction for Proton prefixes ([ValveSoftware/steam-for-linux#6436](https://github.com/ValveSoftware/steam-for-linux/issues/6436)).

As a result:
- 3DMark launches in demo mode even if you own the Advanced Edition.
- Features like Time Spy, Fire Strike Ultra, stress tests, and custom settings remain locked.

Modern 3DMark (UL) reads the paid key from:

```text
[HKEY_CURRENT_USER\Software\UL\3DMark]
"KeyCode"="3DM-ICF-XXXXX-XXXXX-XXXXX-XXXXX"
```

Older builds and a few tests still read the legacy section:

```text
[HKEY_CURRENT_USER\Software\Futuremark\3DMark]
"KeyCode"="..."
```

A real prefix after a normal launch typically contains `KeyCode="STEAM-ENTITLEMENT"` under `Software\UL\3DMark` and an **empty** `KeyCode=""` under `Software\Futuremark\3DMark`. This script treats `STEAM-ENTITLEMENT` and empty values as "not registered" and writes the real key to both sections by default.

### Why Steam cannot just hand over the key
The Steam client never writes CD keys into local files on Linux: `registry.vdf`, `config.vdf`, `localconfig.vdf`, `licensecache`, `appinfo.vdf`, `htmlcache` and even the Proton `user.reg`/`system.reg` were checked and contain no `3DM-` key. The values are only requested on demand from Steam's connection manager (`k_EMsgClientGetLegacyGameKey`), and no public Steam Web API exposes a user's legacy CD key.

So extraction is a **clipboard bridge**: the script opens Steam's CD keys dialog (`steam://cdkeys/223850`), you click the key once, and the script reads it from the clipboard and injects it. If a real key is already present in local Steam data or an existing prefix, that is used first.

---

## Features
- **Key extraction from Steam**: `--from-steam` opens the CD keys dialog and waits for the key on the clipboard (`wl-paste`, `xclip`, or `xsel`).
- **Local discovery**: Reuses a real `3DM-...` key already stored in Steam files or a previously configured prefix.
- **Auto-detection**: Finds Proton prefixes for native Steam (`~/.local/share/Steam`) and Flatpak Steam (`~/.var/app/com.valvesoftware.Steam`), plus any extra libraries listed in `libraryfolders.vdf` (e.g. `/mnt/python/Games/Steam`).
- **Correct registry location**: Writes `Software\UL\3DMark` **and** `Software\Futuremark\3DMark` by default (configurable with `--section`).
- **DLC keys**: `--timespy-key` and `--portroyal-key` write `TimeSpyKeyCode` / `PortRoyalKeyCode` into the UL section.
- **Safe & idempotent**: Backs up `user.reg.bak`, replaces values in place without duplicating sections, verifies every write, and skips files already holding the same values.
- **Secrets hygiene**: Keys are masked in output unless `--show-key` is passed.
- **Includes Known Proton Fixes**: Documents launch parameter workarounds (`--use-gl=osmesa`) and DirectX shader compiler requirements (`d3dcompiler_43`, `d3dcompiler_47`).
- **Time Spy / Night Raid unlocker**: `patch_3dmark_compat.sh` removes the launcher's bogus SSSE3 compatibility gate (SystemInfo cannot report CPU instruction sets under Wine) with a byte-identical, revertible backup.
- **Steam install handling**: discovers every Steam library (native, Flatpak, `libraryfolders.vdf`, `/mnt` and `/media`), and with `--install` requests AppID `223850` through the Steam client and waits for the download before patching.

---

## Prerequisites
1. Install 3DMark via Steam — or let the script do it with `--install`.
2. Launch 3DMark at least once through Proton so Steam generates the Wine prefix (`compatdata/223850/pfx`).
3. Own the paid edition. The key is visible in Steam under **3DMark -> Manage -> CD keys**.
4. `python3` (only for the launcher patch; the key-injection path is pure bash).

Real Steam keys are shaped like `3DM-ICF-#####-#####-#####-#####` (5-character groups); older keys use 4-character groups. The script accepts 4-6 character groups.

On Wayland install `wl-clipboard` (`wl-paste`); on X11 install `xclip` or `xsel`.

---

## Usage

### 0. Full setup, including the download

```bash
./setup_3dmark.sh --install --from-steam
```
`--install` makes Steam download AppID `223850` when it is missing (waiting up to
`--install-timeout`, default 3600 s) and then applies the launcher patch. Without
`--install` the script only works with an existing installation and says so.

### 1. Extract the key from Steam (recommended)
```bash
./setup_3dmark.sh --from-steam
```
The script tries local Steam data first. If nothing is found it opens the CD keys dialog and polls the clipboard for up to 120 seconds (`--wait SECONDS`):
1. Steam opens **3DMark -> Manage -> CD keys**.
2. Click the 3DMark Advanced key to copy it.
3. The script picks it up and writes both registry sections.

To only open the dialog yourself:
```bash
./setup_3dmark.sh --open-cdkeys
```

### 2. Key already on the clipboard
```bash
./setup_3dmark.sh --clipboard
# or pipe it, which keeps it out of shell history
pbpaste | ./setup_3dmark.sh -k -
```

### 3. Apply Key via Command Line
```bash
./setup_3dmark.sh -k "3DM-ICF-XXXXX-XXXXX-XXXXX-XXXXX"
```

### 4. Interactive Mode
Run without arguments. The script checks local Steam data, then the clipboard, then prompts on a TTY:
```bash
./setup_3dmark.sh
```

### 5. Dry Run (Preview Only)
Show detected prefixes and planned writes without touching files:
```bash
./setup_3dmark.sh --dry-run --from-steam
```

### 6. Custom Prefix, AppID, or Section
```bash
# Explicit prefix path (with or without /pfx, or pointing at user.reg)
./setup_3dmark.sh -p ~/.local/share/Steam/steamapps/compatdata/223850 -k "KEY"

# Explicit AppID
./setup_3dmark.sh -a 223850 -k "KEY"

# Only the modern UL section (or: --section futuremark)
./setup_3dmark.sh --section ul -k "KEY"

# Include DLC keys (UL section only)
./setup_3dmark.sh --from-steam \
  --timespy-key "3DM-SPY-XXXXX-XXXXX-XXXXX-XXXXX" \
  --portroyal-key "3DM-PR-XXXXX-XXXXX-XXXXX-XXXXX"

# Show the full key instead of the masked form
./setup_3dmark.sh -k "KEY" --show-key --dry-run
```

### Options
| Option | Description |
| :--- | :--- |
| `-k, --key KEY` | Registration key; `-` reads it from stdin |
| `--from-steam` | Discover locally, else open the CD keys dialog and poll the clipboard |
| `--clipboard` | Read the key from the clipboard without prompting |
| `--wait SECONDS` | Timeout for `--from-steam` (default `120`) |
| `--open-cdkeys` | Open `steam://cdkeys/223850` and exit |
| `-p, --prefix PATH` | Explicit compatdata prefix, `pfx` directory, or `user.reg` |
| `-a, --appid ID` | Target AppID (default: `223850` and `231350`) |
| `--section ul\|futuremark\|both` | Registry sections to write (default `both`) |
| `--timespy-key K` | Also write `TimeSpyKeyCode` (UL section) |
| `--portroyal-key K` | Also write `PortRoyalKeyCode` (UL section) |
| `--install` | Ensure 3DMark is installed; if missing, request AppID `223850` from Steam and wait for the download |
| `--install-timeout SECONDS` | Maximum wait for that download (default `3600`) |
| `--game-dir PATH` | Explicit 3DMark install directory for the compatibility patch |
| `--no-compat-patch` | Skip the Time Spy/Night Raid launcher patch |
| `--show-key` | Do not mask the key in logs |
| `--dry-run` | Show actions without modifying files |
| `-h, --help` | Show help |

The Time Spy / Night Raid compatibility patch is applied automatically (see
[issue 4](#4-your-cpu-does-not-support-ssse-3-time-spy-night-raid)); pass
`--no-compat-patch` to keep the launcher untouched.

### Exit codes
| Code | Meaning |
| :--- | :--- |
| `0` | Success or already registered / nothing to do |
| `1` | Invalid option or value |
| `2` | No 3DMark Proton prefix found (launch the game once after installing) |
| `3` | Registry verification failed after writing |
| `4` | No usable key (`STEAM-ENTITLEMENT`, timeout, invalid key) |

---

## Common 3DMark on Linux Issues & Fixes

### 1. UI Crash / Black Window on Launch (CEF Error)
3DMark uses Chromium Embedded Framework (CEF) for its UI, which can crash on certain Mesa/Vulkan drivers.
- **Fix**: In Steam, right-click **3DMark** -> **Properties** -> **General** -> **Launch Options**, set:
  ```text
  --use-gl=osmesa
  ```

### 2. Shader Compilation Errors / Missing DirectX Runtime
Certain benchmarks (Time Spy, Fire Strike) require native DirectX shader compiler DLLs.
- **Fix**: Install required DLL overrides using `protontricks`:
  ```bash
  protontricks 223850 d3dcompiler_43 d3dcompiler_47
  ```

### 3. Still in Demo Mode After Injecting the Key
- Confirm the key is visible under `Software\UL\3DMark -> KeyCode` (not just the Futuremark section).
- Fully exit 3DMark and Steam's game process, then relaunch. Proton reads `user.reg` at prefix startup.
- Restore `user.reg.bak` and rerun if a write was interrupted.

### 4. "Your CPU does not support SSSE 3" (Time Spy, Night Raid)

3DMark's Futuremark SystemInfo scanner (`FMSIScan.exe`, a 32-bit helper) never emits its
`<Processor_Instruction_Sets>` block under Wine/Proton. The launcher therefore believes the
CPU has no SSSE3/SSE4.1 support and blocks every test that requires it, even though the CPU
does support those instructions (check with `grep -o ssse3 /proc/cpuinfo`).

Confirmed symptom in the generated report:

```bash
P=~/.local/share/Steam/steamapps/compatdata/223850/pfx
grep -c Processor_Instruction_Sets \
  "$P/drive_c/ProgramData/UL/3DMark/tmp/"fm-si-*.xml   # -> 0 on every scan
```

The `--systeminfo=off` launch option and `INCLUDE_UNSUPPORTED_TESTS` setting do **not** help:
they only hide/display the tests, the compatibility gate still blocks them.

**Fix**: disable the single launcher check that converts the missing report into a blocking
problem (the CPU really can run the tests):

```bash
./patch_3dmark_compat.sh              # patch (idempotent)
./patch_3dmark_compat.sh --install    # download via Steam first if 3DMark is missing
./patch_3dmark_compat.sh --check      # exit 0 if installed, 3 otherwise
./patch_3dmark_compat.sh --dry-run    # just show what would happen
./patch_3dmark_compat.sh --revert     # restore the pristine launcher
```

`setup_3dmark.sh` runs this automatically after detecting the prefix; add `--install` to the
key-registration command and it also downloads 3DMark through Steam (`steam://install/223850`)
and waits for the download before patching.

The script backs up the stock launcher to `bin/x64/choros.jar.orig`, then rewrites only
`com/futuremark/choros/service/ProductStateServiceImpl.class`, replacing
`checkCpusForInstructionsSetRequirement(...)` with a plain `return`. Everything else in the
jar is untouched. Use `-g /path/to/3DMark` if the install is outside the usual Steam
libraries.

Notes:
- Steam's "Verify integrity of game files" (or any game update) will restore the stock jar;
  just rerun the script afterwards.
- Install-related exit codes: `3` = 3DMark not installed (use `--install`), `6` = no usable
  Steam client or the download timed out.
- This is an unsupported client-side workaround. UL treats native Linux/Proton as
  unsupported, so online result validation may still fail even though the benchmark runs and
  scores locally.

---

## Repository layout

| Path | Purpose |
| :--- | :--- |
| `setup_3dmark.sh` | Registry key registration + Steam install/patch orchestration |
| `patch_3dmark_compat.sh` | Launcher patch for Time Spy / Night Raid (`--install`, `--check`, `--revert`) |
| `test_setup.sh` | Registry/prefix/install test suite |
| `test_patch_compat.sh` | Launcher-patch test suite |
| `fixtures/make_choros_fixture.py` | Synthetic `choros.jar` used by the patch tests |

## Verification / Running Tests

Registry/prefix handling (no game installation required):
```bash
./test_setup.sh
```

Launcher patch and Steam install handling (builds a synthetic `choros.jar` and a stub Steam
client, no game installation required):
```bash
./test_patch_compat.sh
```

Expected output for both:
```text
All tests passed successfully.
```
