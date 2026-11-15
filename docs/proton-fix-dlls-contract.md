# `.slssteam_fix_dlls` Shared Contract

Status: **Frozen** (shared between the Lumen/LuaTools layer and `moon64`).

## Purpose

Defines the per-game DLL override list produced when a Proton/Windows fix is
installed into a Steam game directory. Keeping an explicit file avoids guessing
`WINEDLLOVERRIDES` from every DLL in the game tree (which would accidentally
override engine/DirectX DLLs such as `D3D12.dll` or `D3D12Core.dll`).

## Location and Ownership

- **Path:** `<game_install_dir>/.slssteam_fix_dlls`
  - `<game_install_dir>` is recorded as `"installPath"` in
    `~/.local/share/Lumen/fix_installs/<appid>/manifest.json`.
- **Writer:** Lumen / LuaTools layer (`fixinstall.lua`, LuaTools fix downloader).
- **Consumer (overrides):** Lumen / LuaTools (`fix_overlays`) builds per-game
  Proton `WINEDLLOVERRIDES` launch options from this list.
- **Reader (diagnostics):** `moon64 doctor` inspects this file **read-only** for
  managed games and warns when missing (informational, non-blocking).
- **Launcher boundary:** `bin/wrapper.64.sh` never reads, writes, or modifies
  `.slssteam_fix_dlls`, and never overwrites or unsets user `WINEDLLOVERRIDES`
  or `PROTON_*` variables.

## File Format (Frozen)

- Plain UTF-8 / ASCII text file with LF (`\n`) line endings (readers strip any
  trailing `\r`).
- **One DLL basename per line** — filename only, with `.dll` extension, no
  directory components, no `=n,b` override flags, and no `;` separators:

  ```text
  OnlineFix64.dll
  SteamOverlay64.dll
  winmm.dll
  steam_api64.dll
  ```

- Deduplicated case-insensitively by the writer; original filename casing is
  preserved.
- An **empty file** (0 bytes / 0 non-empty lines) is valid and explicitly means
  *"fix installed; no DLL overrides required"*.
- Blank lines (if present) are ignored by readers.
