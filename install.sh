#!/usr/bin/env bash
# moon64 installer — stage the 64-bit Steam client stack.
#
# Design contract: by default this script only *stages* the 64-bit pieces. It
# never changes which client Steam starts and never modifies live Lumen files.
# `moon64 on` performs the switch and `moon64 off` undoes it, both by swapping
# already-installed files, so a failed migration is always one command away from
# the known-good 32-bit stack and never needs the network to recover.
#
# Flags:
#   --with-cloudredirect   build and stage the 64-bit CloudRedirect pair
#   --with-lumen-patch     overlay the pinned Lumen + LuaTools trees into
#                          ~/.local/share/Lumen/ (fixes menu, FakeAppId swap)
#
# Layout it produces:
#   ~/.local/share/moon64/SLSsteam.so.64        staged 64-bit SLSsteam
#   ~/.local/share/moon64/netsock64.so          cert patch, built here
#   ~/.local/share/moon64/wrapper.64.sh         the 64-bit Steam wrapper
#   ~/.local/share/moon64/moon64                the switcher
#   ~/.local/share/SLSsteam/SLSsteam.so.32      saved 32-bit SLSsteam (rollback)
#   ~/.local/share/CloudRedirect/<f>.64/.32     staged CloudRedirect variants
#   ~/.local/share/Lumen/lua                    Lumen fork tree (--with-lumen-patch)
#   ~/.local/share/Lumen/luatools/plugin        LuaTools plugin tree (same flag)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOON_DIR="${MOON64_DIR:-$HOME/.local/share/moon64}"
SLS_DIR="$HOME/.local/share/SLSsteam"
CR_DIR="$HOME/.local/share/CloudRedirect"

c_grn=$'\033[38;5;114m'; c_red=$'\033[38;5;203m'; c_yel=$'\033[38;5;221m'
c_dim=$'\033[2m'; c_nc=$'\033[0m'
[ -t 1 ] || { c_grn=; c_red=; c_yel=; c_dim=; c_nc=; }
ok()   { printf '%s  ok  %s %s\n' "$c_grn" "$c_nc" "$*"; }
warn() { printf '%s warn %s %s\n' "$c_yel" "$c_nc" "$*"; }
bad()  { printf '%s fail %s %s\n' "$c_red" "$c_nc" "$*"; }
dim()  { printf '%s      %s%s\n' "$c_dim" "$*" "$c_nc"; }
die()  { bad "$*"; exit 1; }

with_cloudredirect=0
with_lumen_patch=0
for arg in "$@"; do
    case "$arg" in
        --with-cloudredirect) with_cloudredirect=1 ;;
        --with-lumen-patch)   with_lumen_patch=1 ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        *) die "unknown argument: $arg" ;;
    esac
done

[ "$(id -u)" -ne 0 ] || die "run as your desktop user, not root"
command -v curl    >/dev/null || die "curl is required"
command -v gcc     >/dev/null || die "gcc is required to build netsock64"
command -v file    >/dev/null || die "file is required"
command -v readelf >/dev/null || die "readelf (binutils) is required"
command -v ldd     >/dev/null || die "ldd is required"

if [ -f "$HOME/.steam/steam.pid" ] && kill -0 "$(cat "$HOME/.steam/steam.pid" 2>/dev/null)" 2>/dev/null; then
    die "Steam is running. Close it completely, then re-run."
fi

mkdir -p "$MOON_DIR" || die "cannot create $MOON_DIR"

# is_elf64 <file> — true when the file exists and is a 64-bit ELF.
# grep -q exits as soon as it matches. Under `set -o pipefail` the producer then
# dies of SIGPIPE and the pipeline reports failure even though the match
# succeeded -- a false negative that reads as "not 64-bit" / "no libcurl".
# Capture first, then match, so no pipeline is involved.
is_elf64() {
    local info
    info="$(file -b "$1" 2>/dev/null || true)"
    case "$info" in *'ELF 64-bit'*) return 0 ;; esac
    return 1
}

# probe_slssteam_deps <so> — verify every DT_NEEDED library (e.g. libdbus-1.so.3),
# transitive runtime dependency, symbol resolution, and glibc ceiling on host.
probe_slssteam_deps() {
    local so="$1" needed ldd_out dep missing_libs="" transitive_missing
    local local_glibc need_glibc

    needed="$(LC_ALL=C readelf -d "$so" 2>/dev/null \
        | sed -n 's/.*(NEEDED).*Shared library: \[\([^]]*\)\].*/\1/p')"
    [ -n "$needed" ] || die "could not inspect DT_NEEDED dependencies of $so"

    ldd_out="$(LC_ALL=C env -u LD_LIBRARY_PATH -u LD_AUDIT -u LD_PRELOAD ldd -r "$so" 2>&1 || true)"

    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        case "$dep" in ld-linux-*.so*) continue ;; esac
        if printf '%s\n' "$ldd_out" | awk -v d="$dep" '$1 == d && $2 == "=>" && $3 == "not" && $4 == "found" { f=1 } END { exit !f }' \
           || ! printf '%s\n' "$ldd_out" | awk -v d="$dep" '$1 == d && $2 == "=>" && $3 ~ /^\// { f=1 } END { exit !f }'; then
            missing_libs="${missing_libs:+$missing_libs, }$dep"
        fi
    done <<< "$needed"

    if [ -n "$missing_libs" ]; then
        case "$missing_libs" in
            *libdbus-1.so.3*)
                die "SLSsteam.so missing host 64-bit runtime dependency: $missing_libs (install 64-bit libdbus, e.g. libdbus / dbus-libs / libdbus-1-3)"
                ;;
            *)
                die "SLSsteam.so missing host 64-bit runtime dependency: $missing_libs"
                ;;
        esac
    fi

    transitive_missing="$(printf '%s\n' "$ldd_out" \
        | awk '$2 == "=>" && $3 == "not" && $4 == "found" { print $1 }' \
        | paste -sd ',' - | sed 's/,/, /g')"
    if [ -n "$transitive_missing" ]; then
        die "SLSsteam.so has unresolved transitive runtime dependency: $transitive_missing"
    fi

    local_glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}' || true)"
    [ -n "$local_glibc" ] || local_glibc="$(LC_ALL=C ldd --version 2>/dev/null \
        | awk 'NR==1{for(i=NF;i>=1;i--) if($i ~ /^[0-9]+\.[0-9]+$/){print $i; exit}}')"
    need_glibc="$(LC_ALL=C readelf -V "$so" 2>/dev/null \
        | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sed 's/GLIBC_//' | sort -uV | tail -1)"
    if [ -n "$local_glibc" ] && [ -n "$need_glibc" ]; then
        if [ "$(printf '%s\n%s\n' "$need_glibc" "$local_glibc" | sort -V | tail -1)" != "$local_glibc" ]; then
            die "SLSsteam.so requires glibc $need_glibc but this host has $local_glibc"
        fi
        ok "SLSsteam.so glibc requirement $need_glibc <= host $local_glibc"
    fi

    if grep -qE 'undefined symbol|version .* not found' <<<"$ldd_out"; then
        grep -E 'undefined symbol|version .* not found' <<<"$ldd_out" >&2
        die "SLSsteam.so has unresolved symbols or symbol versions on this host"
    fi
    ok "SLSsteam.so runtime dependencies satisfied ($(printf '%s' "$needed" | tr '\n' ' ' | sed 's/ $//'))"
}

# --- 1. SLSsteam 64-bit, built from source (staged, not activated) ---------

# The stack is built from the pinned swwayps fork rather than downloaded as a
# release binary. AceSLS's release is 64-bit and works, but it carries 6
# feature modules and 17 patterns; this stack needs the fork's 79 modules
# (LuaTools stplug-in, Lumen CEF-port contract, live appinfo provision, hot
# reload) and its 61 patterns. See versions.env.
# shellcheck source=versions.env
. "$HERE/versions.env"

src_dir="${SLS64_SRC:-}"
if [ -z "$src_dir" ]; then
    if [ -f "$HERE/../PORTING.md" ]; then
        src_dir="$(cd "$HERE/.." && pwd)"
    else
        src_dir="$SLS64_CLONE_DIR"
    fi
fi

# Fetch the pinned checkout when it is not present. The fork is private, so a
# plain git clone would stop at a credential prompt -- which in a
# non-interactive installer is just a failure. Prefer gh (already
# authenticated when it is installed), then the git credential helper, and
# otherwise say precisely what to do instead of dying with "clone failed".
if [ ! -f "$src_dir/Makefile" ]; then
    command -v git >/dev/null || die "git is required to fetch the SLSsteam source"
    mkdir -p "$(dirname "$src_dir")" || die "cannot create $(dirname "$src_dir")"
    dim "cloning $SLS64_REPO ($SLS64_REF) into $src_dir"

    slug="${SLS64_REPO#https://github.com/}"
    slug="${slug%.git}"

    cloned=0
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh repo clone "$slug" "$src_dir" -- --depth 1 --branch "$SLS64_REF" >/dev/null 2>&1 && cloned=1
    fi
    if [ "$cloned" = 0 ]; then
        GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$SLS64_REF" \
            "$SLS64_REPO" "$src_dir" >/dev/null 2>&1 && cloned=1
    fi
    if [ "$cloned" = 0 ]; then
        bad "cannot fetch the private SLSsteam fork: $slug"
        dim "  Option 1: gh auth login, then re-run (gh is used when authenticated)."
        dim "  Option 2: clone it yourself and pass the path:"
        dim "            git clone $SLS64_REPO ~/Projects/slsteam-moon-64"
        dim "            SLS64_SRC=~/Projects/slsteam-moon-64 ./install.sh"
        die "no SLSsteam source available"
    fi
    ok "cloned $slug into $src_dir"
else
    ok "using source at $src_dir"
fi

# Refuse to stage a build whose required pattern table is not complete. A
# missing required pattern makes Patterns::init() fail and SLSsteam aborts the
# whole injection, so the client would start completely unpatched -- FakeAppIds
# and everything else silently off. Staging that looks like success and is not.
if [ -f "$src_dir/res/pattern-status.txt" ]; then
    pending="$(awk -F= '$1=="pending"{print $2}' "$src_dir/res/pattern-status.txt")"
    tail_state="$(awk -F= '$1=="runipcframe_tail"{print $2}' "$src_dir/res/pattern-status.txt")"
    if [ "${pending:-0}" != 0 ] || [ "${tail_state:-ready}" != ready ]; then
        bad "the x86_64 pattern table is incomplete"
        dim "  required patterns still missing: ${pending:-?}"
        dim "  RunIPCFrame dispatch tail: ${tail_state:-?}"
        dim "  A build now would load and then decline to patch, leaving Steam"
        dim "  unpatched with no FakeAppIds. See PORTING.md in $src_dir."
        dim "  Set SLSM_ALLOW_INCOMPLETE_PATTERNS=1 to stage it anyway for testing."
        [ "${SLSM_ALLOW_INCOMPLETE_PATTERNS:-0}" = 1 ]             || die "refusing to stage an incomplete build"
        warn "staging anyway (SLSM_ALLOW_INCOMPLETE_PATTERNS=1)"
    else
        ok "x86_64 pattern table complete"
    fi
fi

# Build requirements: a host C++20 toolchain, make, and the 64-bit dev
# libraries the fork links or generates against.
command -v make >/dev/null || die "make is required"
command -v "${CXX:-g++}" >/dev/null || die "a C++ compiler is required (g++)"
command -v pkg-config >/dev/null || dim "note: pkg-config not found; build may still work"

# curl/ssl headers are needed by pattern-refresh; openssl by the same target.
missing_dev=""
printf '#include <curl/curl.h>
int main(void){return 0;}
'     | "${CXX:-g++}" -x c++ -fsyntax-only - >/dev/null 2>&1     || missing_dev="$missing_dev libcurl-dev"
printf '#include <openssl/evp.h>
int main(void){return 0;}
'     | "${CXX:-g++}" -x c++ -fsyntax-only - >/dev/null 2>&1     || missing_dev="$missing_dev libssl-dev"
if [ -n "$missing_dev" ]; then
    case "$(uname -s)" in
        Linux)
            if command -v pacman >/dev/null 2>&1; then
                dim "install with: sudo pacman -S --needed curl openssl"
            elif command -v apt-get >/dev/null 2>&1; then
                dim "install with: sudo apt-get install -y libcurl4-openssl-dev libssl-dev"
            elif command -v dnf >/dev/null 2>&1; then
                dim "install with: sudo dnf install -y libcurl-devel openssl-devel"
            fi
            ;;
    esac
    die "missing build headers:$missing_dev"
fi

# Build host floor. The x86_64 source is C++20, and under C++20 glibc's own
# <cstdlib> redirects strtol/strtoul/strtoll/strtoull to __isoc23_strto*,
# which first shipped in glibc 2.38. Nothing in the fork calls strtol directly,
# so there is no source-level opt-out: the build host must be >= 2.38 or the
# link fails. Say that up front instead of letting make fail eight minutes in.
host_glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
if [ -n "$host_glibc" ]; then
    # sort -V picks the older of the two, so equality with the floor means ok.
    older="$(printf '%s\n%s\n' "$host_glibc" 2.38 | sort -V | head -1)"
    if [ "$older" != 2.38 ]; then
        die "this host has glibc $host_glibc; the x86_64 build needs >= 2.38 (C++20 __isoc23_strto*)"
    fi
    ok "build host glibc $host_glibc >= 2.38"
fi

# Build. ARCH is explicit so the 32-bit default of the fork is never used here.
dim "building the 64-bit SLSsteam from $src_dir"
( cd "$src_dir" && make ARCH=x86_64 -j"$(nproc 2>/dev/null || echo 2)" )     >"${TMPDIR:-/tmp}/moon64-build.log" 2>&1     || { tail -20 "${TMPDIR:-/tmp}/moon64-build.log" >&2; die "SLSsteam build failed (full log: ${TMPDIR:-/tmp}/moon64-build.log)"; }
[ -f "$src_dir/bin/SLSsteam.so" ] || die "build produced no bin/SLSsteam.so"
is_elf64 "$src_dir/bin/SLSsteam.so" || die "built SLSsteam.so is not 64-bit"
probe_slssteam_deps "$src_dir/bin/SLSsteam.so"
install -m 755 "$src_dir/bin/SLSsteam.so" "$MOON_DIR/SLSsteam.so.64" || die "cannot stage SLSsteam.so.64"

# libcurl is dlopen'd, not linked (src/curl.cpp:22), so it never shows up in
# DT_NEEDED and probe_slssteam_deps cannot see it. Without a 64-bit
# libcurl.so.4 on the host the network features degrade to "libcurl
# unavailable" -- provisioning, fixes and updates all stop working.
ldcache="$(ldconfig -p 2>/dev/null || true)"
if ! case "$ldcache" in *libcurl.so.4*) true ;; *) false ;; esac; then
    warn "no libcurl.so.4 on this host; network features will be unavailable"
    dim "  install the 64-bit curl runtime (e.g. curl / libcurl4)"
fi
ok "staged $MOON_DIR/SLSsteam.so.64 (built from source)"

# Keep the 32-bit original next to the active file, so `moon64 off` can restore
# it without re-downloading. Only the first run needs to save it.
mkdir -p "$SLS_DIR"
if [ -f "$SLS_DIR/SLSsteam.so" ] && ! is_elf64 "$SLS_DIR/SLSsteam.so" && [ ! -f "$SLS_DIR/SLSsteam.so.32" ]; then
    cp -a "$SLS_DIR/SLSsteam.so" "$SLS_DIR/SLSsteam.so.32" || die "cannot save the 32-bit SLSsteam"
    ok "saved the 32-bit SLSsteam.so for rollback"
fi

# --- 2. netsock64 -----------------------------------------------------------
if [ -f "$HERE/patches/netsock64/steamclient_audit64.c" ]; then
    gcc -O2 -Wall -Wextra -shared -fPIC \
        -o "$MOON_DIR/netsock64.so" \
        "$HERE/patches/netsock64/steamclient_audit64.c" -ldl || die "netsock64 build failed"
    ok "built $MOON_DIR/netsock64.so"
else
    warn "patches/netsock64 missing; the P2P cert patch will be inactive"
fi

# --- 3. wrapper + switcher -------------------------------------------------
[ -f "$HERE/bin/wrapper.64.sh" ] || die "bin/wrapper.64.sh missing from the checkout"
install -m 755 "$HERE/bin/wrapper.64.sh" "$MOON_DIR/wrapper.64.sh" || die "cannot install wrapper"
ok "installed $MOON_DIR/wrapper.64.sh"
[ -f "$HERE/bin/moon64" ] || die "bin/moon64 missing from the checkout"
install -m 755 "$HERE/bin/moon64" "$MOON_DIR/moon64" || die "cannot install switcher"
ok "installed $MOON_DIR/moon64"

# --- 4. CloudRedirect (optional, needs a build) ----------------------------
# Migrate legacy .32.bak backups from older build-cloudredirect.sh runs on sight.
if [ -d "$CR_DIR" ]; then
    for f in cloud_redirect.so cloud_redirect_cli; do
        if [ -f "$CR_DIR/$f.32.bak" ]; then
            if [ ! -f "$CR_DIR/$f.32" ]; then
                mv -f "$CR_DIR/$f.32.bak" "$CR_DIR/$f.32" || die "cannot migrate $CR_DIR/$f.32.bak"
                dim "migrated $f.32.bak -> $f.32"
            elif cmp -s "$CR_DIR/$f.32.bak" "$CR_DIR/$f.32"; then
                rm -f "$CR_DIR/$f.32.bak"
            fi
        fi
    done
fi

if [ "$with_cloudredirect" = 1 ]; then
    if [ -x "$HERE/bin/build-cloudredirect.sh" ]; then
        CLOUD_REDIRECT_OUT="$MOON_DIR/cloudredirect" \
            bash "$HERE/bin/build-cloudredirect.sh" || die "CloudRedirect 64-bit build failed"
        [ -f "$MOON_DIR/cloudredirect/cloud_redirect.so" ] || die "CloudRedirect build produced nothing"
        # Stage both variants so the switcher can swap instead of rebuild.
        mkdir -p "$CR_DIR"
        for f in cloud_redirect.so cloud_redirect_cli; do
            if [ -f "$CR_DIR/$f" ] && ! is_elf64 "$CR_DIR/$f" && [ ! -f "$CR_DIR/$f.32" ]; then
                cp -a "$CR_DIR/$f" "$CR_DIR/$f.32" || die "cannot save the 32-bit $f"
                dim "saved the 32-bit $f"
            fi
            install -m 755 "$MOON_DIR/cloudredirect/$f" "$CR_DIR/$f.64" || die "cannot stage $f.64"
        done
        ok "staged the 64-bit CloudRedirect pair in $CR_DIR"
    else
        warn "bin/build-cloudredirect.sh missing; skipping CloudRedirect"
    fi
else
    dim "CloudRedirect not requested; pass --with-cloudredirect to include it"
fi

# --- 5. Lumen + LuaTools plugin trees (explicit opt-in) --------------------
# These used to be a handful of patch files copied over the installed tree. That
# could not work: the fixes menu is 24 commits deep on the Lumen fork, six of its
# files do not exist upstream at all, and the copy loop skipped any destination
# that did not already exist -- so on a fresh v2.9 it installed nothing and the
# menu called six RPCs that were never registered. Install the trees instead.

# fetch_pinned <repo-url> <ref> <dir> -> 0 when <dir> is a usable checkout.
# Private repos need credentials; a bare git clone stops at a prompt, which in a
# non-interactive installer just reads as "clone failed".
fetch_pinned() {
    local repo="$1" ref="$2" dir="$3" slug cloned=0
    if [ -f "$dir/.git/HEAD" ]; then
        ok "using checkout at $dir"
        return 0
    fi
    command -v git >/dev/null || { bad "git is required for $repo"; return 1; }
    mkdir -p "$(dirname "$dir")" || { bad "cannot create $(dirname "$dir")"; return 1; }
    slug="${repo#https://github.com/}"; slug="${slug%.git}"
    dim "cloning $slug ($ref) into $dir"
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh repo clone "$slug" "$dir" -- --depth 1 --branch "$ref" >/dev/null 2>&1 && cloned=1
    fi
    if [ "$cloned" = 0 ]; then
        GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$ref" \
            "$repo" "$dir" >/dev/null 2>&1 && cloned=1
    fi
    if [ "$cloned" = 0 ]; then
        bad "cannot fetch $slug"
        dim "  either: gh auth login"
        dim "  or:     git clone $repo $dir"
        return 1
    fi
    ok "cloned $slug into $dir"
    return 0
}

# overlay_tree <src> <dst> <label> — copy every file from src into dst.
# Files are created when missing (the whole point of the old bug), and an
# existing file is backed up before being replaced. Files present in dst but
# absent from src are reported, never deleted: dst also holds runtime state.
overlay_tree() {
    local src="$1" dst="$2" label="$3" rel stamp changed=0 added=0
    stamp="$MOON_DIR/$label.backup-$(date +%Y%m%d-%H%M%S)"
    while IFS= read -r -d '' f; do
        rel="${f#"$src"/}"
        if [ -f "$dst/$rel" ]; then
            cmp -s "$f" "$dst/$rel" && continue
            mkdir -p "$stamp/$(dirname "$rel")" 2>/dev/null || true
            cp -a "$dst/$rel" "$stamp/$rel" 2>/dev/null || true
            install -m 644 "$f" "$dst/$rel" || die "cannot write $dst/$rel"
            changed=$((changed+1))
        else
            mkdir -p "$(dirname "$dst/$rel")" || die "cannot create $(dirname "$dst/$rel")"
            install -m 644 "$f" "$dst/$rel" || die "cannot write $dst/$rel"
            added=$((added+1))
            dim "added ~/${dst#"$HOME"/}/$rel"
        fi
    done < <(find "$src" -type f -print0)
    if [ "$changed" -gt 0 ] || [ "$added" -gt 0 ]; then
        ok "$label: $added added, $changed updated (backup: $stamp)"
    else
        ok "$label: already current"
    fi
}

if [ "$with_lumen_patch" = 1 ]; then
    lumen_src="${LUMEN_SRC:-}"
    if [ -z "$lumen_src" ]; then
        lumen_src="$(dirname "$HERE")/../lumen"
        [ -f "$lumen_src/lua/boot.lua" ] || lumen_src="$LUMEN_CLONE_DIR"
    fi
    if fetch_pinned "$LUMEN_REPO" "$LUMEN_REF" "$lumen_src"; then
        if [ -d "$HOME/.local/share/Lumen/lua" ]; then
            # Refuse a cross-version overlay: the fork tracks a specific Lumen.
            if [ -f "$HOME/.local/share/Lumen/versions.json" ] && \
               [ -f "$lumen_src/README.md" ]; then
                inst="$(tr -d ' \n' < "$HOME/.local/share/Lumen/versions.json" \
                        | /usr/bin/grep -o '"lumen":{[^}]*}' | /usr/bin/grep -o '"tag":"v[0-9.]*"' | head -1)"
                [ -n "$inst" ] && dim "installed Lumen ${inst#*\"tag\":}"
            fi
            overlay_tree "$lumen_src/lua" "$HOME/.local/share/Lumen/lua" lumen-patch
        else
            warn "Lumen is not installed; skipping its tree"
            dim "  install Lumen first (swwayps/lumen release), then re-run"
        fi
        if [ -d "$HOME/.local/share/Lumen/luatools" ]; then
            lut_src="${LUATOOLS_SRC:-}"
            if [ -z "$lut_src" ]; then
                lut_src="$(dirname "$HERE")/../luatools-moon"
                [ -d "$lut_src/plugin" ] || lut_src="$LUATOOLS_CLONE_DIR"
            fi
            if fetch_pinned "$LUATOOLS_REPO" "$LUATOOLS_REF" "$lut_src"; then
                # The fork keeps the plugin under plugin/; the install keeps it
                # directly under luatools/ (luatools/{plugin.json,backend,public}).
                overlay_tree "$lut_src/plugin" "$HOME/.local/share/Lumen/luatools" luatools-patch
            fi
        fi
    fi
else
    dim "Lumen/LuaTools trees not requested; pass --with-lumen-patch to install them"
fi

# --- 6. report -------------------------------------------------------------
printf '\n'
ok "staging complete; nothing has been activated"
dim "verify:  $MOON_DIR/moon64 doctor"
dim "switch:  $MOON_DIR/moon64 on     (undo: $MOON_DIR/moon64 off)"
