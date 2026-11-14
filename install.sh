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
#   --with-lumen-patch     apply LuaTools patches into ~/.local/share/Lumen/
#
# Layout it produces:
#   ~/.local/share/moon64/SLSsteam.so.64        staged 64-bit SLSsteam
#   ~/.local/share/moon64/netsock64.so          cert patch, built here
#   ~/.local/share/moon64/wrapper.64.sh         the 64-bit Steam wrapper
#   ~/.local/share/moon64/moon64                the switcher
#   ~/.local/share/SLSsteam/SLSsteam.so.32      saved 32-bit SLSsteam (rollback)
#   ~/.local/share/CloudRedirect/<f>.64/.32     staged CloudRedirect variants
#   ~/.local/share/Lumen/{lua,...}              LuaTools patches (--with-lumen-patch)
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
is_elf64() { [ -f "$1" ] && file -b "$1" 2>/dev/null | grep -q 'ELF 64-bit'; }

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

    if printf '%s\n' "$ldd_out" | grep -qE 'undefined symbol|version .* not found'; then
        printf '%s\n' "$ldd_out" | grep -E 'undefined symbol|version .* not found' >&2
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

# Build. ARCH is explicit so the 32-bit default of the fork is never used here.
dim "building the 64-bit SLSsteam from $src_dir"
( cd "$src_dir" && make ARCH=x86_64 -j"$(nproc 2>/dev/null || echo 2)" )     >"${TMPDIR:-/tmp}/moon64-build.log" 2>&1     || { tail -20 "${TMPDIR:-/tmp}/moon64-build.log" >&2; die "SLSsteam build failed (full log: ${TMPDIR:-/tmp}/moon64-build.log)"; }
[ -f "$src_dir/bin/SLSsteam.so" ] || die "build produced no bin/SLSsteam.so"
is_elf64 "$src_dir/bin/SLSsteam.so" || die "built SLSsteam.so is not 64-bit"
probe_slssteam_deps "$src_dir/bin/SLSsteam.so"
install -m 755 "$src_dir/bin/SLSsteam.so" "$MOON_DIR/SLSsteam.so.64" || die "cannot stage SLSsteam.so.64"
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

# --- 5. Lumen / LuaTools patches (explicit opt-in) -------------------------
if [ "$with_lumen_patch" = 1 ]; then
    if [ -d "$HERE/patch/lumen" ] && [ -d "$HOME/.local/share/Lumen/lua" ]; then
        stamp="$MOON_DIR/lumen-patch.backup-$(date +%Y%m%d-%H%M%S)"
        changed=0
        while IFS= read -r -d '' src; do
            rel="${src#"$HERE"/patch/lumen/}"
            dst="$HOME/.local/share/Lumen/$rel"
            [ -f "$dst" ] || continue
            cmp -s "$src" "$dst" && continue
            mkdir -p "$stamp/$(dirname "$rel")" 2>/dev/null || true
            cp -a "$dst" "$stamp/$rel" 2>/dev/null || true
            install -m 644 "$src" "$dst" || die "cannot patch $dst"
            changed=$((changed+1))
            dim "patched ~/${dst#"$HOME"/}"
        done < <(find "$HERE/patch/lumen" -type f -print0)
        if [ "$changed" -gt 0 ]; then
            ok "applied $changed Lumen patch(es) (backup: $stamp)"
        else
            ok "Lumen already patched"
        fi
    else
        dim "Lumen not installed or no patches present; skipping"
    fi
else
    dim "Lumen patches not requested; pass --with-lumen-patch to apply"
fi

# --- 6. report -------------------------------------------------------------
printf '\n'
ok "staging complete; nothing has been activated"
dim "verify:  $MOON_DIR/moon64 doctor"
dim "switch:  $MOON_DIR/moon64 on     (undo: $MOON_DIR/moon64 off)"
