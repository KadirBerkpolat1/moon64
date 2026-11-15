# Publishing the prebuilt `SLSsteam.so`

`./install.sh --prebuilt` downloads the 64-bit `SLSsteam.so` from a release of
[slsteam-moon-64](https://github.com/KadirBerkpolat1/slsteam-moon-64) instead of
building it. moon64 only consumes that release; it is built and published from
slsteam-moon-64. Until a release exists, `--prebuilt` reports the failed
download and builds from source.

The default URL is `SLS64_PREBUILT_URL` in [`versions.env`](versions.env):

```
https://github.com/KadirBerkpolat1/slsteam-moon-64/releases/latest/download/SLSsteam.so
```

`latest` resolves to the newest release that is neither a draft nor a
pre-release, so the release must be published as a normal release.

## What the release must contain

All three assets, attached to the same release:

| asset | where it comes from |
|---|---|
| `SLSsteam.so` | `dist/portable/x86_64/SLSsteam.so` from `scripts/build-portable-container.sh --arch x86_64` in slsteam-moon-64 |
| `SLSsteam.so.sha256` | `sha256sum SLSsteam.so`, i.e. the `SLSsteam.so` line of the build's `SHA256SUMS` |
| `pattern-status.txt` | `res/pattern-status.txt` as measured on that exact `SLSsteam.so`, plus a `binary_sha256=` line naming it |

`install.sh` fetches `pattern-status.txt` from the same directory as the
library, and `<url>.sha256` next to it.

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
```

`install.sh` refuses the download, with nothing staged, unless that line
appears exactly once and matches the downloaded library. Append it only after
measuring that exact library: the line asserts that the counts above it were
measured on these bytes.

## Publishing

From a slsteam-moon-64 checkout whose `res/pattern-status.txt` was measured on
the library this build produces:

```sh
scripts/build-portable-container.sh --arch x86_64 --out dist/portable/x86_64
out=dist/portable/x86_64
sum="$(sha256sum "$out/SLSsteam.so" | cut -d' ' -f1)"
cp res/pattern-status.txt "$out/pattern-status.txt"
printf 'binary_sha256=%s\n' "$sum" >> "$out/pattern-status.txt"
printf '%s  SLSsteam.so\n' "$sum" > "$out/SLSsteam.so.sha256"
gh release create <tag> --repo KadirBerkpolat1/slsteam-moon-64 \
    "$out/SLSsteam.so" "$out/SLSsteam.so.sha256" "$out/pattern-status.txt"
```

## What `install.sh --prebuilt` checks

| check | on failure |
|---|---|
| `SLSsteam.so` and `pattern-status.txt` download | says so and builds from source |
| `SLSsteam.so.sha256` matches, when published | stops; nothing staged |
| no `SLSsteam.so.sha256` published | warns, and relies on the `binary_sha256=` binding |
| 64-bit x86-64 ELF shared object | stops; nothing staged |
| exactly one `binary_sha256=` in `pattern-status.txt`, equal to the download | stops; nothing staged |
| the pattern gate (`pending=0`, `runipcframe_tail=ready`) | stops; nothing staged |
| libraries, symbol versions and glibc requirement resolve on this host | stops; nothing staged |

`tests/test-prebuilt.sh` exercises each row with `file://` fixtures laid out
like the release.

The `.sha256` file and the binding come from the same release as the library.
They catch corruption, mixed-up assets and stale status files, but not a
compromised release: anyone who can replace the library can replace the files
that describe it. Protecting against that needs a signature checked against a
key pinned in this repo, which is not in place yet.
