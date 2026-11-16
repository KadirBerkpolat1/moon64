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
  [slsteam-moon-x64](https://github.com/KadirBerkpolat1/slsteam-moon-x64),
  AGPL-3.0-only), CloudRedirect (from our fork
  [cloudredirect-moon](https://github.com/KadirBerkpolat1/cloudredirect-moon) of
  swwayps/cloudredirect-moon, only with `--with-cloudredirect`), and the Lumen and LuaTools fork trees
  (only with `--with-lumen-patch`). Each is cloned from the pin in
  [`versions.env`](versions.env) and keeps its own licence.
  `netsock64.so` is built from this repo's own source unless it is
  downloaded with `--prebuilt` (below).
- **Downloaded at install time, not redistributed here:** upstream
  [AceSLS/SLSsteam](https://github.com/AceSLS/SLSsteam)'s 32-bit release
  (AGPL-3.0), only when no 32-bit SLSsteam is installed, as the rollback
  target. Pinned with its SHA-256 in [`versions.env`](versions.env).
  With `--prebuilt` (which is what the [one-liner](#quickstart) runs), also the
  64-bit `SLSsteam.so` release asset of
  [slsteam-moon-x64](https://github.com/KadirBerkpolat1/slsteam-moon-x64)
  (AGPL-3.0-only) instead of building it, and `netsock64.so` when the release
  publishes it — see [Prebuilt binaries](#prebuilt-binaries).

## Quickstart

Install the **native** Steam client (not Flatpak) and start it once, so it
downloads its 64-bit client into `steamrt64/`. Then:

```sh
curl -fsSL https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/get.sh | bash
~/.local/share/moon64/moon64 doctor
~/.local/share/moon64/moon64 on
```

[`get.sh`](get.sh) downloads `install.sh`, `bin/moon64`, `bin/wrapper.64.sh`,
`versions.env` and the cert patch source
`patches/netsock64/steamclient_audit64.c` with `curl` into a temporary
directory, prints each URL and SHA-256, and runs `install.sh --prebuilt` from
there. That downloads the prebuilt `SLSsteam.so` from the latest
slsteam-moon-x64 release and verifies it (see
[Prebuilt binaries](#prebuilt-binaries)): no `git`, no compiler. The current
release carries `SLSsteam.so` alone, so `install.sh` builds the P2P cert patch
from the downloaded source with `gcc`, and runs without it when there is no
compiler, which needs `gcc`; without `gcc` that install still
succeeds, warns that the cert patch is inactive, and co-op joins that need
peer-to-peer fail. It stops an idle Steam client itself
(`moon64 stop-steam`) and refuses only while a game is running.

`get.sh` never installs packages. If prerequisites are missing it shows them
with the package-manager command, and the re-run that lets `install.sh`
install them through a `sudo -n` that never prompts:

```sh
curl -fsSL https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/get.sh | bash -s -- --install-deps
```

`bash get.sh --dry-run` prints what it would download and run and changes
nothing. `MOON64_REF` picks the moon64 branch, tag or commit (default `main`);
`MOON64_DIR` and `SLSM_PREBUILT_URL` reach `install.sh` unchanged. If
`install.sh` fails, `get.sh` puts `~/.local/share/moon64` back exactly as it
found it, or removes it if this run created it, and removes
`~/.local/share/SLSsteam` too if this run created that.

The install only stages files; nothing changes until `moon64 on`.
`moon64 doctor` is the pre-flight: fix everything it reports as bad before
running `moon64 on`. After `on`, start Steam normally.

Optional, before installing:

- Upstream [SLSsteam](https://github.com/AceSLS/SLSsteam) (the 32-bit
  release), if you want `moon64 off` to return to a working 32-bit SLSsteam
  stack. Without it, `install.sh` fetches the upstream 32-bit library as the
  rollback target and `off` returns to stock Steam — see
  [Rollback](#rollback).
- [Lumen](https://github.com/swwayps/lumen) for `--with-lumen-patch`, and the
  32-bit CloudRedirect for cloud saves. Both flags need the source checkout
  below.

### Build from source (developers)

```sh
git clone https://github.com/KadirBerkpolat1/moon64.git
cd moon64
./install.sh
~/.local/share/moon64/moon64 doctor
~/.local/share/moon64/moon64 on
```

This clones slsteam-moon-x64 and compiles `SLSsteam.so` and `netsock64.so` on
this machine, so it needs the toolchain in [Requirements](#requirements).
`./install.sh --prebuilt` from a checkout is the binary path again. Optional
pieces are flags to the same installer:

```sh
./install.sh --with-cloudredirect --with-lumen-patch
```

If prerequisites are missing, `install.sh` lists them with the package-manager
command to install them; `./install.sh --install-deps` runs that command for
you.

## Requirements

The binary install (`get.sh`, or `install.sh --prebuilt`) needs **no compiler
and no `git`**: `SLSsteam.so` comes from the release, and so does
`netsock64.so` when the release publishes it, as the current one does (see the
`gcc` row for a release that does not). A source build still needs them
because it compiles both on this machine: `SLSsteam.so` from the C++20
slsteam-moon-x64 source (cloned with `git`, built with `make` and `g++` against
the libcurl and OpenSSL headers), and `netsock64.so` from
`patches/netsock64/steamclient_audit64.c` with `gcc`.

| Requirement | Needed for | Checked by |
|---|---|---|
| Linux x86_64 with **glibc >= 2.38** | building the 64-bit `SLSsteam.so` (C++20 `__isoc23_strto*`); a library built on this host then needs this host's glibc to load | `install.sh` refuses to build on older glibc; with `--prebuilt` it checks the downloaded library's glibc requirement against this host instead |
| Native Steam in `~/.steam/steam`, `~/.local/share/Steam` or `~/.steam/debian-installation`, with `steamrt64/steam` and `steamrt64/steamclient.so` present | the 64-bit client | `moon64 doctor` |
| Upstream 32-bit SLSsteam | the rollback target | fetched by `install.sh` when absent; reported by `moon64 doctor` — see [Rollback](#rollback) |
| `7z` (p7zip) or `bsdtar` (libarchive) | unpacking the upstream 32-bit release | `install.sh` (warning only: without it there is no rollback target; installed by `--install-deps`) |
| Running as your desktop user, not root | file ownership under `~/.local/share` | `install.sh` |
| `curl`, `file`, `readelf` (binutils), `ldd` | downloads and ELF checks | `install.sh` (installed by `--install-deps`) |
| `git`, `g++` (C++20), `make`, libcurl and OpenSSL development headers | **source build only**: cloning slsteam-moon-x64 and compiling `SLSsteam.so`. The binary install needs none of them | `install.sh` (installed by `--install-deps`; with `--prebuilt` only asked for if no usable prebuilt `SLSsteam.so` can be downloaded) |
| `gcc` | **source build only**: compiling `netsock64.so`. With `--prebuilt`, only if the release has no `netsock64.so`, and then optional: without `gcc` the install succeeds and the P2P cert patch is inactive | `install.sh` |
| 64-bit `libdbus-1.so.3` and a `libstdc++` with `GLIBCXX_3.4.32` (GCC 13+) | loading `SLSsteam.so` in the client | `install.sh`, `moon64 doctor` |
| 64-bit `libcurl.so.4` | SLSsteam's network features (loaded at runtime) | `install.sh` (warning only) |
| `cmake` | `--with-cloudredirect` only | `bin/build-cloudredirect.sh` |
| An installed Lumen (`~/.local/share/Lumen/lua`) | `--with-lumen-patch` only | `install.sh` (skips with a warning) |
| `pkg-config` | optional | `install.sh` (note only) |

Check the glibc floor:

```sh
getconf GNU_LIBC_VERSION
```

`install.sh` checks the command-line tools and headers above before it does
anything else and prints everything that is missing as one list, with the
exact `pacman`, `apt-get` or `dnf` command that installs it. It installs
nothing by itself. To let it run that command, pass `--install-deps`:

```sh
./install.sh --install-deps
```

With that flag it runs the package manager through `sudo -n`, which never
prompts. If sudo needs a password, `install.sh` says so and stops; run the
printed command yourself, then run `install.sh` again. The runtime libraries
(`libdbus`, `libstdc++`, `libcurl.so.4`) and `cmake` are not covered by this
and are still reported by the checks listed in the table.

On Arch Linux and derivatives, this covers the binary install:

```sh
sudo pacman -S --needed curl file binutils dbus libarchive
```

and this everything in the table, for a source build:

```sh
sudo pacman -S --needed base-devel git curl openssl file binutils dbus cmake libarchive
```

**Flatpak Steam is not supported.** moon64 only looks in the three native
Steam roots listed above; a Flatpak install under
`~/.var/app/com.valvesoftware.Steam` is never found.

### Prebuilt binaries

```sh
./install.sh --prebuilt
```

downloads the 64-bit `SLSsteam.so` from `SLSM_PREBUILT_URL`, or by default
from the slsteam-moon-x64 release asset named by `SLS64_PREBUILT_URL` in
[`versions.env`](versions.env), and `netsock64.so` from the same release
directory when the release carries one, and stages them without compiling
anything. The release must publish `pattern-status.txt` next to the library,
naming the `SLSsteam.so` it was measured on; a release that also carries
`netsock64.so` must name it there too. `v1.0.0`, an earlier release, carries
only the library, and its `pattern-status.txt` names only `SLSsteam.so`.
`install.sh` checks the downloads as strictly as a build:

- `<file>.sha256`, when published, must match; a mismatch stops the install.
  Without one, `install.sh` warns and relies on the binding below.
- `pattern-status.txt` must contain exactly one `binary_sha256=` line equal to
  the downloaded `SLSsteam.so`'s SHA-256 and, in a release that carries
  `netsock64.so`, exactly one `netsock64_sha256=` line equal to the downloaded
  `netsock64.so`'s, so a status file from another build cannot vouch for either.
- Every downloaded library must be a 64-bit x86-64 ELF shared object.
- `pattern-status.txt` must pass the same pattern gate as a source build.
- `SLSsteam.so`'s libraries, symbol versions and glibc requirement must
  resolve on this host.

A failed check stops the install, with nothing staged. When `SLSsteam.so` or
its `pattern-status.txt` cannot be downloaded (for example offline),
`install.sh` says so and builds from source instead, under the usual
requirements and the glibc >= 2.38 floor. When the release has no
`netsock64.so` and its `pattern-status.txt` names none, it is built from
`patches/netsock64` if that source and `gcc` are present; otherwise the install
still succeeds and says that the P2P cert patch is inactive. When
`pattern-status.txt` names a `netsock64.so` (`netsock64_sha256=`) that cannot
be downloaded, the install stops with nothing staged. The final summary,
`~/.local/share/moon64/slsteam64.state`, `netsock64.state` and `moon64 doctor`
all say where each binary came from.

The current slsteam-moon-x64 release (the one
[`releases/latest`](https://github.com/KadirBerkpolat1/slsteam-moon-x64/releases/latest)
points at) publishes `SLSsteam.so`, its `.sha256` and a `pattern-status.txt`
bound to the library by `binary_sha256=`, so `--prebuilt` stages the library
after the checks above with no compiler. It carries no `netsock64.so`: the
P2P cert patch is built from `patches/netsock64` (which `get.sh` downloads)
when `gcc` is installed, and stays inactive otherwise. A release that does
publish `netsock64.so`, bound by `netsock64_sha256=`, is accepted the same
way.
[`RELEASING.md`](RELEASING.md) lists what a release must contain and how to
build it.

## What is in here

| path | what it is |
|---|---|
| `get.sh` | the `curl \| bash` installer: fetches `install.sh`, `bin/moon64`, `bin/wrapper.64.sh`, `versions.env` and `patches/netsock64/steamclient_audit64.c` (plus `bin/build-cloudredirect.sh` with `--with-cloudredirect`), then runs `install.sh --prebuilt` |
| `patches/netsock64/steamclient_audit64.c` | `LD_AUDIT` shim that patches the cert-check function in the 64-bit `steamclient.so` at load time |
| `bin/build-cloudredirect.sh` | builds CloudRedirect 64-bit from a pinned commit of our fork |
| `bin/wrapper.64.sh` | the 64-bit Steam launcher (what `SLSsteam/path/steam` becomes) |
| `bin/moon64` | `on` / `off` / `status` / `doctor` switcher |
| `install.sh` | stages every 64-bit piece; activates nothing |
| `RELEASING.md` | what a slsteam-moon-x64 release must contain for `--prebuilt` and `get.sh` |
| `versions.env` | pinned sources: the slsteam-moon-x64, Lumen and LuaTools forks, the CloudRedirect commit, the prebuilt release URL and the 32-bit rollback release |

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
| `SLSsteam.so` | upstream release | built from source at install time (slsteam-moon-x64, pinned in `versions.env`), or its release asset with `--prebuilt` |
| `netsock64.so` (P2P cert patch) | **impossible** — anchor absent | built here, or its release asset with `--prebuilt` |
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
untouched and write a line to `~/.cache/moon64/netsock.log`.
Recovering a broken client from a blind patch is not possible; refusing to patch
is always recoverable. See `patches/netsock64/README.md` for the anchors and how
to re-derive them for a new client build.

## 64-bit limits worth knowing

- `cloud_redirect.so` is `LD_PRELOAD`ed through the whole client chain: the outer
  `steam` bootstrapper leaves it in `LD_PRELOAD` and only the inner client (inside
  the pressure-vessel container) loads it, so the *host* glibc is the ceiling.
  The build needs `GLIBC_2.38` (from glibc's C23 `__isoc23_*` redirects) — fine
  on a current distro, too new for an older one. `build-cloudredirect.sh` checks
  this against the local glibc and refuses rather than producing a hook that
  cannot load.
- Cloud saves stay inactive if only the 32-bit CloudRedirect pair is installed.
  `moon64 doctor` reports that rather than silently starting without them.
- `netsock64.so` is never committed to this repo: it is built from
  `patches/netsock64` at install time (the current slsteam-moon-x64 release
  does not carry it). A release that does carry it is accepted, bound by
  `netsock64_sha256=` to the `pattern-status.txt` published with it.

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

Where the 32-bit `SLSsteam.so.32` comes from:

- If a 32-bit `SLSsteam.so` is already in `~/.local/share/SLSsteam`,
  `install.sh` (or `moon64 on`) saves that one.
- Otherwise `install.sh` downloads upstream AceSLS SLSsteam release
  `20261106120254`, the last one that ships a 32-bit library (pinned with its
  SHA-256 in [`versions.env`](versions.env)). It checks the digest and that
  `bin/SLSsteam.so` is a 32-bit i386 ELF, saves it as `SLSsteam.so.32`, and
  records the URL, version and both digests in
  `~/.local/share/moon64/rollback32.state`. A digest or ELF-class mismatch stops
  the install. No network, or no `7z`/`bsdtar` to unpack it, only costs the
  rollback target: the install continues with a warning.

`moon64 doctor` shows which of the two you have. Without either, `off` refuses
rather than leave a 64-bit library behind:

```
fail  cannot restore 32-bit stack: /home/you/.local/share/SLSsteam/SLSsteam.so.32 missing while active SLSsteam.so is 64-bit (re-run install.sh with network access to fetch one)
```

`off` returns the launcher to what it was before `on`. On a machine that never
had upstream SLSsteam, that is Steam's own desktop entry: `off` removes the
override, removes the `SLSsteam/path/steam` wrapper `on` installed (only if it
is still moon64's), and puts the Steam client switches
(`.steam-enable/disable-steamrt64-client`) back as `on` found them instead of
forcing the 32-bit client. The restored `SLSsteam.so` is left in place, but
nothing loads it, so Steam starts without SLSsteam until you set up upstream's
launcher. It and `SLSsteam.so.32` stay on purpose: the `.32` is the verified
upstream download `install.sh` provisioned for `off` to restore, not a leftover,
and `moon64 doctor` says so. `tests/test-install-e2e.sh` checks that the whole
home directory then differs from the freshly installed state only by that file.
