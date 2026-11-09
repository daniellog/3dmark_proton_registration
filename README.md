# 3DMark Proton Registration & Configuration

Automated CLI tool to configure 3DMark (Steam AppIDs `223850` / `231350`) on Linux under Proton and inject the paid Steam CD/registration key directly into the Wine prefix registry.

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

---

## Prerequisites
1. Install 3DMark via Steam.
2. Launch 3DMark at least once through Proton so Steam generates the Wine prefix (`compatdata/223850/pfx`).
3. Own the paid edition. The key is visible in Steam under **3DMark -> Manage -> CD keys**.

Real Steam keys are shaped like `3DM-ICF-#####-#####-#####-#####` (5-character groups); older keys use 4-character groups. The script accepts 4-6 character groups.

On Wayland install `wl-clipboard` (`wl-paste`); on X11 install `xclip` or `xsel`.

---

## Usage

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
| `--show-key` | Do not mask the key in logs |
| `--dry-run` | Show actions without modifying files |
| `-h, --help` | Show help |

### Exit codes
| Code | Meaning |
| :--- | :--- |
| `0` | Success or already registered / nothing to do |
| `1` | Invalid option or value |
| `2` | No 3DMark Proton prefix found |
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
./patch_3dmark_compat.sh            # patch (idempotent)
./patch_3dmark_compat.sh --dry-run  # just show what would happen
./patch_3dmark_compat.sh --revert   # restore the pristine launcher
```

The script backs up the stock launcher to `bin/x64/choros.jar.orig`, then rewrites only
`com/futuremark/choros/service/ProductStateServiceImpl.class`, replacing
`checkCpusForInstructionsSetRequirement(...)` with a plain `return`. Everything else in the
jar is untouched. Use `-g /path/to/3DMark` if the install is outside the usual Steam
libraries.

Notes:
- Steam's "Verify integrity of game files" (or any game update) will restore the stock jar;
  just rerun the script afterwards.
- This is an unsupported client-side workaround. UL treats native Linux/Proton as
  unsupported, so online result validation may still fail even though the benchmark runs and
  scores locally.

---

## Verification / Running Tests

Registry/prefix handling (no game installation required):
```bash
./test_setup.sh
```

Launcher patch (builds a synthetic `choros.jar`, no game installation required):
```bash
./test_patch_compat.sh
```

Expected output for both:
```text
All tests passed successfully.
```
