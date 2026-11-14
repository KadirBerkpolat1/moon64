# Verification

Every claim below was produced by running the command shown, on this machine:
Linux 7.3.4, glibc 2.44, gcc 16, Steam client builds dated 2026-10-22.

## 1. Anchors exist exactly once, in exactly the right library

`realcheck.c` counts both anchors over the raw file bytes.

| file | size | class | `steamrt64` anchor | `linux64` anchor |
|---|---|---|---|---|
| `steamrt64/steamclient.so` | 52846936 | ELF 64 | **1** | 0 |
| `linux64/steamclient.so` | 47709360 | ELF 64 | 0 | **1** |
| `ubuntu12_32/steamclient.so` | 53504048 | ELF 32 | 0 | 0 |

The last row is the whole motivation for this port: the function being patched
is absent from the 32-bit client, so no 32-bit fix is possible.

## 2. The shim patches, and refuses to guess

Four synthetic libraries, each loaded into a probe that prints the first six
bytes of the target function. `probe` `dlopen`s the library; `LD_AUDIT` runs the
shim.

| case | entry bytes before | after | log |
|---|---|---|---|
| `steamrt64` anchor present | `41 54 49 89 f4 55` | `b8 01 00 00 00 c3` | `anchors steamrt64=1 linux64=0` → `patched` |
| `linux64` anchor present | `41 54 41 89 d4 55` | `b8 01 00 00 00 c3` | `anchors steamrt64=0 linux64=1` → `patched` |
| no anchor | `53 b8 01 00 00 00` | unchanged | `no anchor matched - client build not recognised, memory untouched` |
| two anchors | `41 54 41 89 d4 55` | unchanged | `ambiguous (2 anchors) - refusing to patch` |

Representative log for the success case:

```
[2026-11-15 00:46:51] audit loaded, la_version 2
[2026-11-15 00:46:51] steamclient.so opened: ./steamrt64/steamclient.so
[2026-11-15 00:46:51] ./steamrt64/steamclient.so: text 0x7f757f8fb000-0x7f757f8fc000 (4096 bytes) anchors steamrt64=1 linux64=0
[2026-11-15 00:46:51] patched steamrt64/steamclient.so at 0x7f757f8fb0e9 (offset in mapping 0xe9) -> mov eax,1; ret
```

An earlier revision used `dl_iterate_phdr` and logged only `audit loaded` — the
object is not yet in the link map at `la_objopen`. That is why the shim scans
`/proc/self/maps`; the negative result was visible in the log rather than
silently "working".

Clean compile, no warnings:

```
gcc -O2 -Wall -Wextra -shared -fPIC -o netsock64.so steamclient_audit64.c -ldl
→ 16448 bytes, ELF 64-bit LSB shared object, 0 warning lines
```

## 3. CloudRedirect builds natively for 64-bit

Upstream `build.sh` asserts `ELF 32-bit` and cannot be reused. The CMake project
already has the 64-bit branch (`LINUX_32BIT=OFF` skips `-m32`, `libatomic` and
the i686 include hacks).

```
cmake -S . -B build64 -DCMAKE_BUILD_TYPE=Release -DLINUX_32BIT=OFF   # configure=0
cmake --build build64 --target cloud_redirect cloud_redirect_cli      # build=0, 55/55
```

| artifact | size | class | build id |
|---|---|---|---|
| `cloud_redirect.so` | 2148480 | ELF 64-bit LSB shared object | `7cfd004280caec05af3458cc09721c3f179d20ac` |
| `cloud_redirect_cli` | 14568 | ELF 64-bit LSB pie executable | `8ebd70898a119c322089c8df8521119d41a85104` |

Same sizes and same build id from a clean clone of the pinned commit
`19da05507dc8294a744d74c04ba875d4ca3cf2f7` — the build is reproducible.

Upstream test suite on the 64-bit build: **9/9 passed**
(`cli_packaging`, `cli_folder_provider`, `provider_config`, `linux_stats_scope`,
`linux_stats_no_bridge`, `linux_stats_archive`, `linux_lua_discovery`,
`linux_init_stop`, `linux_late_discovery_queue`).

Symbol resolution and glibc ceiling:

```
ldd -r cloud_redirect.so            → no undefined symbols
GLIBC_* max required                → 2.38  (__isoc23_sscanf/strto*)
host glibc                          → 2.44
```

The `__isoc23_*` symbols are glibc's C23 redirects, not our code. They set a
floor of glibc 2.38 for the preload hook; `build-cloudredirect.sh` compares this
against the host and refuses instead of producing a hook that cannot load.

Loaded into a real 64-bit process:

```
LD_PRELOAD=cloud_redirect.so ./p64
→ [INFO] [ManifestStore]/[TokenStore]/[CloudStorage] init… shutdown complete
→ hello from 64-bit process          (exit 0)
```

## 4. Installer stages only, and the switch is byte-exact

Sandbox `$HOME`, a genuine 32-bit `SLSsteam.so` and CloudRedirect pair, a fake
`steamrt64/steam`, and the original 32-bit wrapper.

Hashes before `on`:

```
91a0b7db… SLSsteam.so            (ELF 32)
91a0b7db… cloud_redirect.so      (ELF 32)
6c68ef9a… cloud_redirect_cli     (ELF 32)
c4893d58… SLSsteam/path/steam    (original wrapper)
```

`moon64 on` → all four replaced by 64-bit equivalents, both
`.steam-enable-steamrt64-client` markers written, `.32` originals saved.

`moon64 off` → **all four hashes identical to the pre-`on` set**, the enable
marker removed and the disable marker written.

Repeated `on`/`on`/`off` → identical result; the saved `.32` copy still hashes
`91a0b7db…`, i.e. cycles cannot degrade the backup:

```
on#1 exit=0
on#2 exit=0   (idempotent)
active=ELF 64-bit LSB shared object
saved-32=ELF 32-bit LSB shared object  sha=91a0b7db…
off  exit=0   after-off sha=91a0b7db…
```

`moon64 status` after `off`:

```
-- client --
      .steam/steam: steamrt64 disabled
  ok  32-bit client selected
-- active libraries --
      SLSsteam.so: 32-bit active, 64-bit staged
      cloud_redirect.so: 32-bit active, 64-bit staged
      netsock64.so: 64-bit active
```

## 5. The wrapper builds the right environment

Real wrapper against a fake `steamrt64/steam` that prints its environment:

```
STEAM_FORCE_CLIENT=steamrt64
LD_AUDIT=<moon64>/netsock64.so:<SLSsteam>/SLSsteam.so
LD_PRELOAD=unset
LD_LIBRARY_PATH=unset
ARGS=--foo bar
```

That is the whole point of the port in four lines: 64-bit client forced, the cert
patch ahead of SLSsteam, and none of the 32-bit scaffolding
(`library-inject.so`, `$SLSDIR/lib32`) that would either fail to load or corrupt
the client.

Degraded paths:

| condition | result |
|---|---|
| `netsock64.so` missing | warns `P2P cert patch inactive`, **starts** |
| SLSsteam missing too | `neither netsock64.so nor SLSsteam.so found; refusing to start`, exit 1 |
| no `steamrt64/steam` | `no steamrt64/steam binary found`, exit 1 |

A 32-bit `cloud_redirect.so` is skipped: the wrapper checks `file` for
`ELF 64-bit` before preloading, so the client cannot be crashed by a stale hook
left over from the 32-bit stack.

## 6. Doctor on the real machine

Run against the live install while the 32-bit stack was still active:

```
-- 64-bit readiness --
  ok   steamrt64 client present
  ok   steamrt64/steamclient.so present
  ok   SLSsteam.so 64-bit staged — run 'moon64 on'
  ok   netsock64.so present
 warn  CloudRedirect 64-bit staged but not active
-- known 64-bit limits --
      library-inject.so (libcurl redirect) has no 64-bit build. The
      64-bit client loads libcurl from its own runtime, so it is not needed.
      $SLSDIR/lib32 (32-bit libcrypto workaround) is likewise dropped.
```

Blocking problems are counted and returned as the exit status, so the switch is
gated on facts rather than on the user reading prose.

## Known binary identities

32-bit stack (live at time of writing, also saved as the rollback source):

| file | size | build id |
|---|---|---|
| `SLSsteam.so` (32) | 16365736 | `8258057d17400d0f32c1a1387e6343cb355ad8d0` |
| `cloud_redirect.so` (32) | 2209220 | `d03bc0de8f04de6a317aa0617371cc8046dc138f` |

64-bit side:

| file | size | build id |
|---|---|---|
| `SLSsteam.so.64` (release `20261112130346`) | 25146688 | `fc9c26ccf3ea2f502fe07441108dc929662709b0` |
| `netsock64.so` (built here) | 16448 | sha256 `ef62057ed98083fcf39922ed6bf53d64d8aeb0d2561327441d8d9b8a1bed7523` |
| `cloud_redirect.so` (built here) | 2148480 | `7cfd004280caec05af3458cc09721c3f179d20ac` |

## Not yet verified

A real mutual P2P join (two machines, both in game, one hosting). That is the
only test that proves the cert patch end to end. Procedure and the log lines to
read are in the root README's motivation section and in the acceptance notes
kept with the memory card for this work.
