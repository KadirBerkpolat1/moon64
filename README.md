# moon64

Run the SLSsteam / LuaTools / CloudRedirect stack on Steam's **64-bit**
`steamrt64` client instead of the 32-bit `ubuntu12_32` one.

The 32-bit client is a dead end for peer-to-peer: the
`steamnetsock-patch` fix that clears SteamNetworkingSockets'
`Cert is not authorized for appid` rejection has no 32-bit counterpart. The
function it patches is not present in `ubuntu12_32/steamclient.so` at all, so
co-op joins that need P2P (Satisfactory, REPO, …) fail no matter how the rest of
the stack is configured. 64-bit is the only client where that path exists.

## What is in here

| path | what it is |
|---|---|
| `patches/netsock64/steamclient_audit64.c` | `LD_AUDIT` shim that patches the cert-check function in the 64-bit `steamclient.so` at load time |
| `bin/build-cloudredirect.sh` | builds CloudRedirect 64-bit from a pinned upstream commit |
| `bin/wrapper.64.sh` | the 64-bit Steam launcher (what `SLSsteam/path/steam` becomes) |
| `bin/moon64` | `on` / `off` / `status` / `doctor` switcher |
| `install.sh` | stages every 64-bit piece; activates nothing |
| `patch/lumen/` | LuaTools `fixinstall.lua` + its menu hook (OnlineFix → `FakeAppIds`) |

## Why a switcher instead of one wrapper

The 32-bit stack is not merely a different build — it is a different *class* of
object. `SLSsteam.so`, `library-inject.so` and `cloud_redirect.so` are
`ELFCLASS32`; a 64-bit client cannot `dlopen` them and cannot load them as
auditors. So the client and the libraries must move together, all or nothing.

That is why `install.sh` only ever *stages* files and `moon64 on|off` is the
only thing that changes which side is live. Every artifact the 64-bit side needs
is already on disk before it is used, so recovery never depends on the network.

## Usage

```sh
./install.sh                      # stage the 64-bit pieces (32-bit stays live)
./install.sh --with-cloudredirect # ...and build + stage the CloudRedirect pair
~/.local/share/moon64/moon64 doctor
~/.local/share/moon64/moon64 on    # switch; then start Steam normally
~/.local/share/moon64/moon64 off   # byte-exact return to the 32-bit stack
```

`off` restores the saved `<file>.32` originals and the saved wrapper, so the
pre-migration state comes back exactly — verified by hash, not by intent.

## Component matrix

| component | 32-bit client | 64-bit client |
|---|---|---|
| `SLSsteam.so` | upstream release | upstream release (`SLSsteam-Any-release.7z`) |
| `netsock64.so` (P2P cert patch) | **impossible** — anchor absent | built here |
| `library-inject.so` (libcurl redirect) | required | **dropped** — the 64-bit client brings its own libcurl |
| `lib32/libcrypto.so.1.1` | SHA-1 workaround | **dropped** — 32-bit only, irrelevant |
| `cloud_redirect.so` (cloud saves) | upstream prebuilt | built here with `-DLINUX_32BIT=OFF` |
| LuaTools `fixinstall.lua` | ours | ours — arch independent |

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

## Rollback

```sh
~/.local/share/moon64/moon64 off
```

Restores `SLSsteam.so.32`, the CloudRedirect `.32` pair and the original wrapper,
and re-asserts the 32-bit client markers. `install.sh` never overwrites an
existing `.32` original, so repeated `on`/`off` cycles cannot degrade it.
