# Publishing the prebuilt `SLSsteam.so`

`./install.sh --prebuilt`, and with it `get.sh`, downloads the 64-bit
`SLSsteam.so` from a release of
[slsteam-moon-x64](https://github.com/KadirBerkpolat1/slsteam-moon-x64) instead
of compiling it. moon64 only consumes that release; it is built and published
from slsteam-moon-x64. The release publishes `SLSsteam.so`, its `.sha256` and
a `pattern-status.txt` with a `binary_sha256=` line naming the library and a
`source_commit=` line naming the commit. It publishes **no `netsock64.so`**:
the P2P cert patch is built from `patches/netsock64` on the user's machine
with `gcc`, or stays inactive when there is no compiler. A release that does
carry `netsock64.so` is still accepted, bound by a `netsock64_sha256=` line.

The default URL is `SLS64_PREBUILT_URL` in [`versions.env`](versions.env):

```
https://github.com/KadirBerkpolat1/slsteam-moon-x64/releases/latest/download/SLSsteam.so
```

`latest` resolves to the newest release that is neither a draft nor a
pre-release, so the release must be published as a normal release.

## What the release must contain

Three assets, attached to the same release, all produced by
`scripts/moon64-assets.sh` in slsteam-moon-x64:

| asset | where it comes from |
|---|---|
| `SLSsteam.so` | `bin/SLSsteam.so` from `scripts/build.sh --portable` (ubuntu-22.04 container, glibc 2.34 floor) |
| `SLSsteam.so.sha256` | `sha256sum SLSsteam.so` |
| `pattern-status.txt` | the committed `res/pattern-status.counts` plus `binary_sha256=` naming that exact library and `source_commit=` naming the commit |

`install.sh` fetches `pattern-status.txt` from the same directory as the
library, and `<file>.sha256` next to it. The counts file is committed to the
repo and the generator refuses to emit a status file whose table would not
pass the install gate, so a release with a regressed locator table fails
before it reaches users.

## Why the container build, never a host build

`SLSsteam.so` is loaded with `LD_AUDIT` into the host's Steam process, so the
`GLIBC_` and `GLIBCXX_` versions it needs are checked against the user's own
glibc and libstdc++. A library is only as portable as the oldest runtime it
was linked against:

- `scripts/build.sh --portable` links in an ubuntu-22.04 image (glibc 2.34),
  and `scripts/check-sls-abi.sh` refuses a build whose symbol floor moved.
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
replaced on its own, or a `latest/download` that moved between the two
requests would pass the gate for a library it never described. So the
published file must name the library it was measured on:

```
binary_sha256=<sha256 of the published SLSsteam.so>
```

`install.sh` refuses the download, with nothing staged, unless the line
appears exactly once and matches the downloaded file. Append it only after
building that exact library: `binary_sha256=` asserts that the counts above it
were measured on these bytes. If a release ever carries `netsock64.so` again,
its `netsock64_sha256=` line binds the same way.

## Publishing

CI (`.github/workflows/release.yml` in slsteam-moon-x64) builds, tests and
publishes on every push to `main`: portable build, `make -k test-ci`,
`scripts/moon64-assets.sh bin/SLSsteam.so release/`, then a `v<timestamp>`
release whose public URLs are verified anonymously before it becomes `latest`.

When Actions is unavailable, the same steps run locally in the same container
image (`slsteam-moon-builder-x86_64`, from `scripts/Dockerfile.x86_64`):

```sh
make clean && make -j"$(nproc)" ARCH=x86_64 && make -k test-ci
scripts/check-sls-abi.sh bin/SLSsteam.so
scripts/moon64-assets.sh bin/SLSsteam.so release/
gh release create <tag> --repo KadirBerkpolat1/slsteam-moon-x64 \
    release/SLSsteam.so release/SLSsteam.so.sha256 release/pattern-status.txt \
    --target "$(git rev-parse HEAD)" --latest
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
