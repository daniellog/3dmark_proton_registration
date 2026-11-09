# 3DMark Proton Registration & Configuration

Automated CLI tool to configure 3DMark (Steam AppIDs `223850` / `231350`) on Linux under Proton and inject the Steam CD/registration key directly into the Wine prefix registry.

---

## The Problem
On Windows, Steam automatically injects CD keys into the Windows registry using `LegacyKeyRegistrationMethod = registry`. 
On Linux, the Steam client does not process this instruction for Proton prefixes ([ValveSoftware/steam-for-linux#6436](https://github.com/ValveSoftware/steam-for-linux/issues/6436)). 

As a result:
- 3DMark launches in demo mode even if you own the Advanced Edition.
- Features like Time Spy, Fire Strike Ultra, stress tests, and custom settings remain locked.
- 3DMark expects the registration key stored at:
  ```text
  [HKEY_CURRENT_USER\Software\Futuremark\3DMark]
  "KeyCode"="<YOUR_KEY>"
  ```

---

## Features
- **Auto-detection**: Automatically finds Proton prefixes for native Steam (`~/.local/share/Steam`) and Flatpak Steam (`~/.var/app/com.valvesoftware.Steam`).
- **Supports Both AppIDs**: Targets both `223850` (3DMark Advanced) and `231350` (3DMark Demo).
- **Direct Registry Injection**: Edits `user.reg` directly without requiring Proton or Wine to be actively running.
- **Safe & Idempotent**: Backs up `user.reg.bak`, replaces existing `KeyCode` without duplicating sections, and verifies syntax on write.
- **Includes Known Proton Fixes**: Outlines launch parameter workarounds (`--use-gl=osmesa`) and DirectX shader compiler requirements (`d3dcompiler_43`, `d3dcompiler_47`).

---

## Prerequisites
1. Install 3DMark via Steam.
2. Launch 3DMark at least once through Proton so Steam generates the Wine prefix (`compatdata/223850/pfx`).
3. Obtain your 3DMark CD key from Steam (Right click 3DMark in Steam -> **Manage** -> **CD keys**).

---

## Usage

### 1. Apply Key via Command Line
```bash
./setup_3dmark.sh -k "3DM-ADV-XXXXX-XXXXX-XXXXX-XXXXX"
```

### 2. Interactive Mode
Run the script without arguments. If a key is not found, you will be prompted:
```bash
./setup_3dmark.sh
```

### 3. Dry Run (Preview Only)
Preview detected prefix paths without modifying files:
```bash
./setup_3dmark.sh --dry-run
```

### 4. Custom Prefix or AppID
Explicitly specify a prefix path or target AppID:
```bash
# Explicit path
./setup_3dmark.sh -p ~/.local/share/Steam/steamapps/compatdata/223850 -k "KEY"

# Explicit AppID
./setup_3dmark.sh -a 223850 -k "KEY"
```

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

---

## Verification / Running Tests
A self-contained test script is included to test registry parsing and updates against temporary prefixes:
```bash
./test_setup.sh
```
Output:
```text
All tests passed successfully.
```
