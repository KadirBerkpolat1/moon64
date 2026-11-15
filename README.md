# moon64

Run the SLSsteam / LuaTools / CloudRedirect stack on Steam's **64-bit**
`steamrt64` client instead of the 32-bit `ubuntu12_32` one.

The 32-bit client is a dead end for peer-to-peer: the
`steamnetsock-patch` fix that clears SteamNetworkingSockets'
`Cert is not authorized for appid` rejection has no 32-bit counterpart. The
function it patches is not present in `ubuntu12_32/steamclient.so` at all, so
co-op joins that need P2P (Satisfactory, REPO, …) fail no matter how the rest of
the stack is configured. 64-bit is the only client where that path exists.

## Licence

AGPL-3.0 — see [`LICENSE`](LICENSE).

- **Derived work in this repo:** `bin/wrapper.64.sh` is derived from
  SLSsteam v2.9's `path/steam` wrapper (AGPL-3.0), which is why the whole
  repo is AGPL-3.0.
- **Built on your machine at install time, not redistributed here:** the
  64-bit `SLSsteam.so` (from
  [slsteam-moon-64](https://github.com/KadirBerkpolat1/slsteam-moon-64),
  AGPL-3.0-only), CloudRedirect (from
  [swwayps/cloudredirect-moon](https://github.com/swwayps/cloudredirect-moon),
  only with `--with-cloudredirect`), and the Lumen and LuaTools fork trees
  (only with `--with-lumen-patch`). Each is cloned from the pin in
  [`versions.env`](versions.env) and keeps its own licence.
  `netsock64.so` is built from this repo's own source.

## Quickstart

On a clean machine, do these first:

1. Install the **native** Steam client (not Flatpak) and start it once, so it
   downloads its 64-bit client into `steamrt64/`.
2. Install upstream [SLSsteam](https://github.com/AceSLS/SLSsteam) (the 32-bit
   release) by following its README, and check that Steam starts with it.
   moon64 hooks into SLSsteam's launcher (`~/.local/share/SLSsteam/path/steam`),
   and that 32-bit install is the only thing `moon64 off` can return to — see
   [Rollback](#rollback).
3. Optional: install [Lumen](https://github.com/swwayps/lumen) if you want
   `--with-lumen-patch`, and the 32-bit CloudRedirect if you want cloud saves.
4. Install everything in [Requirements](#requirements).

Then close Steam, or let the installer close it for you: it stops an idle
Steam client itself (`moon64 stop-steam`) and refuses only while a game is
running.

```sh
git clone https://github.com/KadirBerkpolat1/moon64.git
cd moon64
./install.sh
~/.local/share/moon64/moon64 doctor
~/.local/share/moon64/moon64 on
```

`install.sh` only stages files; the 32-bit stack stays live until `moon64 on`.
`moon64 doctor` is the pre-flight: fix everything it reports as bad before
running `moon64 on`. After `on`, start Steam normally.

Optional pieces are flags to the same installer:

```sh
./install.sh --with-cloudredirect --with-lumen-patch
```

## Requirements

| Requirement | Needed for | Checked by |
|---|---|---|
| Linux x86_64 with **glibc >= 2.38** | building and loading the 64-bit `SLSsteam.so` (C++20 `__isoc23_strto*`) | `install.sh` refuses older glibc |
| Native Steam in `~/.steam/steam`, `~/.local/share/Steam` or `~/.steam/debian-installation`, with `steamrt64/steam` and `steamrt64/steamclient.so` present | the 64-bit client | `moon64 doctor` |
| Upstream 32-bit SLSsteam, already installed | the launcher hook and the rollback target | not checked — see [Rollback](#rollback) |
| Running as your desktop user, not root | file ownership under `~/.local/share` | `install.sh` |
| `git`, `curl`, `file`, `readelf` (binutils), `ldd` | fetching sources, ELF checks | `install.sh` |
| `gcc`, `g++` (C++20), `make` | building `netsock64.so` and `SLSsteam.so` | `install.sh` |
| libcurl and OpenSSL development headers | building `SLSsteam.so` | `install.sh` |
| 64-bit `libdbus-1.so.3` and a `libstdc++` with `GLIBCXX_3.4.32` (GCC 13+) | loading `SLSsteam.so` in the client | `install.sh`, `moon64 doctor` |
| 64-bit `libcurl.so.4` | SLSsteam's network features (loaded at runtime) | `install.sh` (warning only) |
| `cmake` | `--with-cloudredirect` only | `bin/build-cloudredirect.sh` |
| An installed Lumen (`~/.local/share/Lumen/lua`) | `--with-lumen-patch` only | `install.sh` (skips with a warning) |
| `pkg-config` | optional | `install.sh` (note only) |

Check the glibc floor:

```sh
getconf GNU_LIBC_VERSION
```

Arch Linux and derivatives:

```sh
sudo pacman -S --needed base-devel git curl openssl file binutils dbus cmake
```

On Debian/Ubuntu or Fedora, install your compiler toolchain, `git`, `curl`,
`file` and binutils, plus the headers the installer asks for:

```sh
sudo apt-get install -y libcurl4-openssl-dev libssl-dev
```

```sh
sudo dnf install -y libcurl-devel openssl-devel
```

**Flatpak Steam is not supported.** moon64 only looks in the three native
Steam roots listed above; a Flatpak install under
`~/.var/app/com.valvesoftware.Steam` is never found.

## What is in here

| path | what it is |
|---|---|
| `patches/netsock64/steamclient_audit64.c` | `LD_AUDIT` shim that patches the cert-check function in the 64-bit `steamclient.so` at load time |
| `bin/build-cloudredirect.sh` | builds CloudRedirect 64-bit from a pinned upstream commit |
| `bin/wrapper.64.sh` | the 64-bit Steam launcher (what `SLSsteam/path/steam` becomes) |
| `bin/moon64` | `on` / `off` / `status` / `doctor` switcher |
| `install.sh` | stages every 64-bit piece; activates nothing |
| `versions.env` | pinned sources: the slsteam-moon-64, Lumen and LuaTools forks and the CloudRedirect commit |

## Why a switcher instead of one wrapper

The 32-bit stack is not merely a different build — it is a different *class* of
object. `SLSsteam.so`, `library-inject.so` and `cloud_redirect.so` are
`ELFCLASS32`; a 64-bit client cannot `dlopen` them and cannot load them as
auditors. So the client and the libraries must move together, all or nothing.

That is why `install.sh` only ever *stages* files and `moon64 on|off` is the
only thing that changes which side is live. Every artifact the 64-bit side needs
is already on disk before it is used, so recovery never depends on the network.

## Component matrix

| component | 32-bit client | 64-bit client |
|---|---|---|
| `SLSsteam.so` | upstream release | built from source at install time (slsteam-moon-64, pinned in `versions.env`) |
| `netsock64.so` (P2P cert patch) | **impossible** — anchor absent | built here |
| `library-inject.so` (libcurl redirect) | required | **dropped** — the 64-bit client brings its own libcurl |
| `lib32/libcrypto.so.1.1` | SHA-1 workaround | **dropped** — 32-bit only, irrelevant |
| `cloud_redirect.so` (cloud saves) | upstream prebuilt | built here with `-DLINUX_32BIT=OFF` |
| Lumen fixes menu (`fixinstall.lua`) | Lumen fork tree, `--with-lumen-patch` | same tree — arch independent |

The two dropped pieces are the whole reason this is not a one-line change: they
exist only to work around 32-bit defects, and both are actively wrong for a
64-bit client.

## The cert patch

`steamclient_audit64.c` is an `LD_AUDIT` object. In `la_objopen` it finds the
just-opened `steamclient.so` in `/proc/self/maps` and rewrites the first bytes of
the cert-check function to `mov eax,1; ret`, so the check reports success.

`/proc/self/maps` rather than `dl_iterate_phdr` is deliberate: at `la_objopen`
the object is open but not yet in the link map, so `dl_iterate_phdr` silently
finds nothing.

It fails **closed**. Two anchors cover the two client layouts that ship today;
zero matches (unknown future build) or two matches (ambiguous) both leave memory
untouched and write a line to `~/.local/share/moon64/moon64-netsock.log`.
Recovering a broken client from a blind patch is not possible; refusing to patch
is always recoverable. See `patches/netsock64/README.md` for the anchors and how
to re-derive them for a new client build.

## 64-bit limits worth knowing

- `cloud_redirect.so` is `LD_PRELOAD`ed into the client. The client runs on the
  host (not inside the sniper container), so the *host* glibc is the ceiling.
  The build needs `GLIBC_2.38` (from glibc's C23 `__isoc23_*` redirects) — fine
  on a current distro, too new for an older one. `build-cloudredirect.sh` checks
  this against the local glibc and refuses rather than producing a hook that
  cannot load.
- Cloud saves stay inactive if only the 32-bit CloudRedirect pair is installed.
  `moon64 doctor` reports that rather than silently starting without them.
- `netsock64.so` is built from source at install time; there is no prebuilt
  binary in the repo, so a stale artifact can never drift from the source.

## Desktop entry

Starting Steam from the menu, a dock or a `steam://` link goes through Steam's
desktop entry, not through `SLSsteam/path/steam`. `moon64 on` therefore points
every `Exec=` line of `steam.desktop` (and `steam-native.desktop`, when present)
at the wrapper and keeps the arguments, so `Exec=/usr/bin/steam %U` becomes:

```
Exec=/home/you/.local/share/SLSsteam/path/steam %U
```

System files are never edited. If only `/usr/share/applications/steam.desktop`
exists, `on` writes a user-level copy to `~/.local/share/applications/` and
`off` deletes it again. If a user-level entry already exists (upstream
SLSsteam's `setup.sh` creates one), `on` saves it once as
`steam.desktop.moon64-bak`, edits it in place, and `off` puts the saved copy
back byte for byte. Every other line stays as it was; an `LD_AUDIT=` in the
entry that names only SLSsteam's own libraries is dropped, because the wrapper
sets up that stack itself. An `Exec=` that is not a Steam launch (for example
`flatpak run ...`) makes `on` refuse rather than guess; `moon64 doctor` reports
this beforehand, and also reports when the 64-bit stack is active but the entry
would still start stock Steam.

## Rollback

```sh
~/.local/share/moon64/moon64 off
```

`off` restores `SLSsteam.so.32`, the CloudRedirect `.32` pair, the original
wrapper and the Steam desktop entry, re-asserts the 32-bit client markers, and
checks each restored file byte for byte against its saved copy. `install.sh`
never overwrites an existing `.32` original, so repeated `on`/`off` cycles
cannot degrade it.

Rollback is only possible if a 32-bit SLSsteam was installed **before** moon64.
`install.sh` and `moon64 on` save `SLSsteam.so.32` only when a 32-bit
`SLSsteam.so` is already in `~/.local/share/SLSsteam`. On a machine that never
had one there is nothing to go back to, and `off` refuses:

```
fail  cannot restore 32-bit stack: /home/you/.local/share/SLSsteam/SLSsteam.so.32 missing while active SLSsteam.so is 64-bit
```

To get a rollback target, install upstream SLSsteam first (step 2 of the
[Quickstart](#quickstart)), then run `install.sh` and `moon64 on`.
