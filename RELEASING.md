# Publishing the prebuilt `SLSsteam.so` and `netsock64.so`

`./install.sh --prebuilt`, and with it `get.sh`, downloads the 64-bit
`SLSsteam.so` and `netsock64.so` from a release of
[slsteam-moon-64](https://github.com/KadirBerkpolat1/slsteam-moon-64) instead of
compiling them. moon64 only consumes that release; it is built and published
from slsteam-moon-64. The current release, `v1.0.0`, publishes `SLSsteam.so`,
`SLSsteam.so.sha256` and `pattern-status.txt` (with `binary_sha256=` and no
`netsock64_sha256=` line), but not `netsock64.so` or `netsock64.so.sha256`.

The default URL is `SLS64_PREBUILT_URL` in [`versions.env`](versions.env):

```
https://github.com/KadirBerkpolat1/slsteam-moon-64/releases/latest/download/SLSsteam.so
```

`latest` resolves to the newest release that is neither a draft nor a
pre-release, so the release must be published as a normal release.

## What the release must contain

All five assets, attached to the same release:

| asset | where it comes from |
|---|---|
| `SLSsteam.so` | `dist/portable/x86_64/SLSsteam.so` from `scripts/build-portable-container.sh --arch x86_64` in slsteam-moon-64 |
| `SLSsteam.so.sha256` | `sha256sum SLSsteam.so`, i.e. the `SLSsteam.so` line of the build's `SHA256SUMS` |
| `netsock64.so` | the x86-64 `LD_AUDIT` cert patch, built in the same container from `steamclient_audit64.c` |
| `netsock64.so.sha256` | `sha256sum netsock64.so` |
| `pattern-status.txt` | `res/pattern-status.txt` as measured on that exact `SLSsteam.so`, plus a `binary_sha256=` line naming it and a `netsock64_sha256=` line naming `netsock64.so` |

`install.sh` fetches `pattern-status.txt` and `netsock64.so` from the same
directory as the library, and `<file>.sha256` next to each. A release without
`netsock64.so` still installs, but then `netsock64.so` is compiled with `gcc`
on the user's machine, or the P2P cert patch stays inactive if there is no
`gcc`, so the binary install is only compiler-free with all five assets.

## Why the container build, never a host build

`SLSsteam.so` is loaded with `LD_AUDIT` into the host's Steam process, so the
`GLIBC_` and `GLIBCXX_` versions it needs are checked against the user's own
glibc and libstdc++. A library is only as portable as the oldest runtime it was
linked against:

- `build-portable-container.sh` links in an old-glibc image (AlmaLinux 8),
  measures the floor it produced (`abi-floor.txt`) and refuses on regression.
  That floor is what makes a download useful on older distributions.
- A host build needs glibc >= 2.38 for the C++20 `__isoc23_strto*` redirects,
  plus anything newer the build host happens to have. `install.sh --prebuilt`
  checks the library's glibc requirement against the user's glibc and refuses
  it, so a host-built release would fail on exactly the machines `--prebuilt`
  is meant for.

## Binding `pattern-status.txt` to the library

The pattern gate trusts the counts in `pattern-status.txt` (`pending=0`,
`runipcframe_tail=ready`), and those counts are evidence about one particular
build. Without a binding, a status file from an older tag, a status asset
replaced on its own, or a `latest/download` that moved between the two requests
would pass the gate for a library it never described. So the published file
must name the library it was measured on:

```
binary_sha256=<sha256 of the published SLSsteam.so>
netsock64_sha256=<sha256 of the published netsock64.so>
```

`install.sh` refuses the download, with nothing staged, unless each line
appears exactly once and matches the downloaded file. Append them only after
measuring that exact library: `binary_sha256=` asserts that the counts above it
were measured on these bytes, and `netsock64_sha256=` that this `netsock64.so`
was published with them.

## Publishing

From a slsteam-moon-64 checkout whose `res/pattern-status.txt` was measured on
the library this build produces:

```sh
scripts/build-portable-container.sh --arch x86_64 --out dist/portable/x86_64
out=dist/portable/x86_64
sum="$(sha256sum "$out/SLSsteam.so" | cut -d' ' -f1)"
ns="$(sha256sum "$out/netsock64.so" | cut -d' ' -f1)"
cp res/pattern-status.txt "$out/pattern-status.txt"
printf 'binary_sha256=%s\nnetsock64_sha256=%s\n' "$sum" "$ns" >> "$out/pattern-status.txt"
printf '%s  SLSsteam.so\n' "$sum" > "$out/SLSsteam.so.sha256"
printf '%s  netsock64.so\n' "$ns" > "$out/netsock64.so.sha256"
gh release create <tag> --repo KadirBerkpolat1/slsteam-moon-64 \
    "$out/SLSsteam.so" "$out/SLSsteam.so.sha256" \
    "$out/netsock64.so" "$out/netsock64.so.sha256" "$out/pattern-status.txt"
```

## What `install.sh --prebuilt` checks

| check | on failure |
|---|---|
| `SLSsteam.so` and `pattern-status.txt` download | says so and builds from source |
| `SLSsteam.so.sha256` matches, when published | stops; nothing staged |
| no `SLSsteam.so.sha256` published | warns, and relies on the `binary_sha256=` binding |
| `SLSsteam.so` is a 64-bit x86-64 ELF shared object | stops; nothing staged |
| exactly one `binary_sha256=` in `pattern-status.txt`, equal to the download | stops; nothing staged |
| `netsock64.so` download, when `pattern-status.txt` has no `netsock64_sha256=` line | builds it with `gcc`, or without `gcc` warns that the P2P cert patch is inactive |
| `netsock64.so` download, when `pattern-status.txt` names one with `netsock64_sha256=` | stops; nothing staged |
| `netsock64.so.sha256` matches, when published | stops; nothing staged |
| no `netsock64.so.sha256` published | warns, and relies on the `netsock64_sha256=` binding |
| `netsock64.so` is a 64-bit x86-64 ELF shared object | stops; nothing staged |
| exactly one `netsock64_sha256=` in `pattern-status.txt`, equal to the download | stops; nothing staged |
| the pattern gate (`pending=0`, `runipcframe_tail=ready`) | stops; nothing staged |
| libraries, symbol versions and glibc requirement resolve on this host | stops; nothing staged |

`tests/test-prebuilt.sh` and `tests/test-binary-install.sh` exercise each row
with `file://` fixtures laid out like the release.

The `.sha256` file and the binding come from the same release as the library.
They catch corruption, mixed-up assets and stale status files, but not a
compromised release: anyone who can replace the library can replace the files
that describe it. Protecting against that needs a signature checked against a
key pinned in this repo, which is not in place yet.
