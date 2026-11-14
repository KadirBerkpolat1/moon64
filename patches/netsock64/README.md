# netsock64 — the P2P cert patch for the 64-bit client

## The bug it works around

A Windows online fix swaps the AppID in the client (OnlineFix's `FakeAppId`).
SLSsteam reproduces that on Linux through `FakeAppIds` in
`~/.config/SLSsteam/config.yaml`, but `steamclient.so` *additionally* validates
the SDR networking certificate against the AppID it believes it is running as.

When the lobby is hosted or joined under Spacewar (480) while the local ticket
reports something else, the predicate that emits

```
Cert is not authorized for appid %u, only %u
```

returns false. P2P dies about a second later with `PendingConnectionFailure`,
and the netcode assert follows:

```
steamnetworkingsockets_p2p.cpp (449) : m_unConnectionIDRemote
```

Making that predicate return true is the fix. Upstream
[`yesyes0649/steamnetsock-patch`](https://github.com/yesyes0649/steamnetsock-patch)
does exactly this — but its 14-byte pattern was taken from
`linux64/steamclient.so`, while the client a modern 64-bit Steam install
actually runs is `steamrt64/steamclient.so`, which is built with a different
register allocation. Its pattern does not match. Hence this shim.

## How it works

An `LD_AUDIT` object. In `la_objopen`, when a `steamclient.so` under `linux64/`
or `steamrt64/` appears, the shim:

1. finds the library's executable mapping in `/proc/self/maps`,
2. counts both anchors inside that mapping,
3. if exactly one matched, `mprotect`s the page and writes `B8 01 00 00 00 C3`
   (`mov eax, 1; ret`) over the function entry,
4. restores `PROT_READ|PROT_EXEC`.

`/proc/self/maps` rather than `dl_iterate_phdr` is deliberate. At `la_objopen`
the object is open but not yet in the link map, so `dl_iterate_phdr` silently
finds nothing — that failure mode is invisible in the log and cost real
debugging time. The maps scan is authoritative at that moment.

## The two anchors

Bytes are the function entry, little-endian, as they appear in the file.

| anchor | library | bytes |
|---|---|---|
| `ANCHOR_STEAMRT64` | `steamrt64/steamclient.so` | `41 54 49 89 F4 55 48 89 CD 53 44 8B 47 28 89 D3 45 85 C0 0F 85` |
| `ANCHOR_LINUX64` | `linux64/steamclient.so` | `41 54 41 89 D4 55 48 89 CD 53 44 8B 47 28 48 89 F3 45 85 C0 0F 85` |

Same function. The difference is register allocation: `mov %esi,%r12` (3 bytes)
versus `mov %edx,%r12d` (3 bytes) at offset 3, then a 2-byte `mov %edx,%ebx`
versus a 3-byte `mov %rsi,%rbx` at offset 15.

Provenance: Steam client builds dated **2026-10-22**.

```
steamrt64/steamclient.so  52846936 B  steamrt64=1 linux64=0
linux64/steamclient.so    47709360 B  steamrt64=0 linux64=1
ubuntu12_32/steamclient.so 53504048 B  steamrt64=0 linux64=0
```

Exactly one anchor per library, and none in the 32-bit client — which is the
structural reason this cannot be ported back down to `ubuntu12_32`.

## Failure behaviour

| condition | action |
|---|---|
| exactly one anchor | patch, log the file and mapping offset |
| zero anchors | log `no anchor matched - client build not recognised`, memory untouched |
| two or more anchors | log `ambiguous (N anchors) - refusing to patch`, memory untouched |
| `mprotect` fails | log, memory untouched |
| no executable mapping found | log, skip |

Both failure paths are recoverable because nothing was written. There is no
case where a guess is applied.

The log is `~/.local/share/moon64/moon64-netsock.log`; it is appended to on every
Steam start, so the newest block is the one that matters.

## Re-deriving the anchors for a new client build

A Steam update may reallocate registers and invalidate both anchors. The shim
then stops patching and logs it — the client still starts, P2P just regresses.
Re-derivation:

```sh
# 1. locate the diagnostic string
objdump -s -j .rodata ~/.local/share/Steam/steamrt64/steamclient.so \
  | grep -i 'Cert is not authorized'

# 2. find RIP-relative references to it (48 8d 35 / 48 8d 3d to that vaddr)
objdump -d --start-address=<rodata_vaddr-0x2000> \
             --stop-address=<rodata_vaddr+0x2000> \
  ~/.local/share/Steam/steamrt64/steamclient.so | grep '48 8d 3[5d]'

# 3. the reference sits inside the function that formats the message; walk back
#    to the function entry (the `41 54 41 89 … push %r12; push %r12` prologue)
#    and take the first ~22 bytes as the anchor.

# 4. verify it is unique over the whole file before trusting it
python3 - <<'PY'
import sys
anchor = bytes([0x41,0x54,0x49,0x89,0xF4,0x55,0x48,0x89,0xCD,0x53,0x44,0x8B,0x47,0x28,0x89,0xD3,0x45,0x85,0xC0,0x0F,0x85])
data = open(sys.argv[1] if len(sys.argv)>1 else
    '/home/user/.local/share/Steam/steamrt64/steamclient.so','rb').read()
print('matches:', data.count(anchor))
PY
```

A count of exactly 1 is required. Add the new sequence as another
`ANCHOR_*` array and let the uniqueness check keep the shim honest; do not
loosen an anchor into a wildcard to "make it match".

## What this does not do

It does not change the AppID the game sees, does not touch SLSsteam's licence
handling, and does not run in the game process — only inside the Steam client,
which is the process that performs the P2P handshake and evaluates the cert.
The AppID side is `patch/lumen/lua/fixinstall.lua`, which syncs OnlineFix's
`FakeAppId` into SLSsteam's `FakeAppIds` map.
