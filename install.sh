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
#   --install-deps         install missing prerequisites with the distro package
#                          manager (pacman, apt-get, dnf) through `sudo -n`
#   --prebuilt             download the prebuilt x86_64 SLSsteam.so, and
#                          netsock64.so when the release has it
#                          ($SLSM_PREBUILT_URL, default in versions.env),
#                          instead of compiling them; builds SLSsteam.so from
#                          source only if the prebuilt cannot be downloaded
#
# Layout it produces:
#   ~/.local/share/moon64/SLSsteam.so.64        staged 64-bit SLSsteam
#   ~/.local/share/moon64/slsteam64.state       prebuilt or built, and from where
#   ~/.local/share/moon64/netsock64.so          cert patch: the release's with --prebuilt, else built here
#   ~/.local/share/moon64/netsock64.state       prebuilt or built, and from where
#   ~/.local/share/moon64/wrapper.64.sh         the 64-bit Steam wrapper
#   ~/.local/share/moon64/moon64                the switcher
#   ~/.local/share/SLSsteam/SLSsteam.so.32      32-bit SLSsteam for rollback: the one
#                                               already installed, else the pinned
#                                               upstream release (versions.env)
#   ~/.local/share/moon64/rollback32.state      where a fetched .32 came from
#   ~/.local/share/CloudRedirect/<f>.64/.32     staged CloudRedirect variants
#   ~/.local/share/Lumen/lua                    Lumen fork tree (--with-lumen-patch)
#   ~/.local/share/Lumen/luatools/plugin        LuaTools plugin tree (same flag)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# is_uint <val> — true for 1-9 digit unsigned decimal integers (blocks 64-bit arithmetic wrap).
is_uint() {
    local val="${1:-}"
    case "$val" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#val}" -le 9 ]
}

# check_pattern_gate <src_dir> — fail-closed gate on res/pattern-status.txt.
# Staging an incomplete x86_64 pattern table makes Patterns::init() fail and
# SLSsteam aborts all injection, silently leaving Steam unpatched.
check_pattern_gate() {
    local src_dir="$1"
    local status_file="$src_dir/res/pattern-status.txt"
    local arch="" required="" resolved="" pending="" tail_state=""
    local seen_arch=0 seen_required=0 seen_resolved=0 seen_pending=0 seen_tail=0
    local line trimmed key val reason=""

    if [ ! -f "$status_file" ]; then
        reason="status file missing: $status_file"
    else
        while IFS= read -r line || [ -n "$line" ]; do
            line="${line%$'\r'}"
            trimmed="${line#"${line%%[![:space:]]*}"}"
            case "$trimmed" in
                ''|'#'*) continue ;;
                *=*)
                    key="${trimmed%%=*}"
                    val="${trimmed#*=}"
                    case "$key" in
                        arch)             seen_arch=$((seen_arch + 1)); arch="$val" ;;
                        required)         seen_required=$((seen_required + 1)); required="$val" ;;
                        resolved)         seen_resolved=$((seen_resolved + 1)); resolved="$val" ;;
                        pending)          seen_pending=$((seen_pending + 1)); pending="$val" ;;
                        runipcframe_tail) seen_tail=$((seen_tail + 1)); tail_state="$val" ;;
                    esac
                    ;;
            esac
        done < "$status_file"

        if [ "$seen_arch" -ne 1 ] || [ "$arch" != "x86_64" ]; then
            reason="arch must be x86_64 (got: ${arch:-<missing>})"
        elif [ "$seen_required" -ne 1 ] || ! is_uint "$required"; then
            reason="required must be present and numeric (got: ${required:-<missing>})"
        elif [ "$((10#$required))" -lt 1 ]; then
            reason="required must be >= 1 (got: $required)"
        elif [ "$seen_resolved" -ne 1 ] || ! is_uint "$resolved"; then
            reason="resolved must be present and numeric (got: ${resolved:-<missing>})"
        elif [ "$seen_pending" -ne 1 ] || ! is_uint "$pending"; then
            reason="pending must be present and numeric (got: ${pending:-<missing>})"
        elif [ "$seen_tail" -ne 1 ] || [ "$tail_state" != "ready" ]; then
            reason="runipcframe_tail must be 'ready' (got: ${tail_state:-<missing>})"
        elif [ "$((10#$resolved + 10#$pending))" -ne "$((10#$required))" ]; then
            reason="resolved ($resolved) + pending ($pending) != required ($required)"
        elif [ "$((10#$pending))" -ne 0 ]; then
            reason="pending is $pending (must be 0)"
        fi
    fi

    if [ -n "$reason" ]; then
        bad "the x86_64 pattern table is incomplete or invalid: $reason"
        dim "  status file: $status_file"
        dim "  arch=${arch:-?} required=${required:-?} resolved=${resolved:-?} pending=${pending:-?} runipcframe_tail=${tail_state:-?}"
        dim "  A build now would load and then decline to patch, leaving Steam"
        dim "  unpatched with no FakeAppIds. See PORTING.md in $src_dir."
        dim "  Set SLSM_ALLOW_INCOMPLETE_PATTERNS=1 to stage it anyway for testing."
        if [ "${SLSM_ALLOW_INCOMPLETE_PATTERNS:-0}" = "1" ]; then
            warn "WARNING: BYPASSING x86_64 PATTERN-TABLE GATE (SLSM_ALLOW_INCOMPLETE_PATTERNS=1) — build may leave Steam unpatched!"
            return 0
        fi
        return 1
    fi

    ok "x86_64 pattern table complete (arch=$arch, $resolved/$required resolved, pending=$pending, runipcframe_tail=$tail_state)"
    return 0
}

# is_elf32_i386 <file> — true for a 32-bit x86 ELF, the class `moon64 off` restores.
is_elf32_i386() {
    local info
    info="$(file -b "$1" 2>/dev/null || true)"
    case "$info" in 'ELF 32-bit'*', Intel '*) return 0 ;; esac
    return 1
}

# extract_member <archive> <member> <out> — unpack one file with 7z or bsdtar
# (libarchive reads 7z). Returns 2 when neither is installed.
extract_member() {
    local archive="$1" member="$2" out="$3" x
    for x in 7z 7za 7zr; do
        command -v "$x" >/dev/null 2>&1 || continue
        "$x" x -so "$archive" "$member" > "$out" 2>/dev/null && [ -s "$out" ]
        return
    done
    if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xOf "$archive" "$member" > "$out" 2>/dev/null && [ -s "$out" ]
        return
    fi
    return 2
}

# provision_rollback32 — save the pinned upstream 32-bit SLSsteam as
# $SLS_DIR/SLSsteam.so.32 and record its source in $MOON_DIR/rollback32.state.
# Never replaces an existing .32. Returns 1 when it cannot be fetched or
# unpacked (rollback unavailable, warned), 2 when the download fails its
# SHA-256 or 32-bit ELF check (nothing saved).
provision_rollback32() {
    local dst="$SLS_DIR/SLSsteam.so.32" state="$MOON_DIR/rollback32.state"
    local url="${SLSM_SLS32_URL:-${SLS32_URL:-}}" want="${SLSM_SLS32_SHA256:-${SLS32_SHA256:-}}"
    local version="${SLSM_SLS32_VERSION:-${SLS32_VERSION:-}}" member="${SLS32_MEMBER:-bin/SLSsteam.so}"
    local tmp got so_sha xrc part

    if [ -e "$dst" ]; then
        ok "rollback target present: $dst"
        return 0
    fi
    if [ -z "$url" ] || [ -z "$want" ]; then
        warn "no pinned 32-bit SLSsteam release; 'moon64 off' will have no 32-bit stack to restore"
        return 1
    fi
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/moon64-sls32.XXXXXX")" || { warn "cannot create a temporary directory"; return 1; }
    dim "fetching the 32-bit rollback target: upstream SLSsteam $version"
    if ! curl -fsSL --connect-timeout 15 --max-time 300 -o "$tmp/archive" "$url" 2>/dev/null; then
        rm -rf "$tmp"
        warn "cannot download $url; 'moon64 off' will have no 32-bit stack to restore"
        dim "  re-run install.sh with network access to fetch it"
        return 1
    fi
    got="$(sha256sum "$tmp/archive" | cut -d' ' -f1)"
    if [ "$got" != "$want" ]; then
        rm -rf "$tmp"
        bad "$url: sha256 $got does not match the pinned $want"
        return 2
    fi
    extract_member "$tmp/archive" "$member" "$tmp/SLSsteam.so"
    xrc=$?
    if [ "$xrc" = 2 ]; then
        rm -rf "$tmp"
        warn "neither 7z nor bsdtar is installed to unpack $url; 'moon64 off' will have no 32-bit stack to restore"
        dim "  install p7zip (7z) or libarchive (bsdtar) and re-run install.sh"
        return 1
    elif [ "$xrc" != 0 ]; then
        rm -rf "$tmp"
        bad "cannot extract $member from $url"
        return 2
    fi
    if ! is_elf32_i386 "$tmp/SLSsteam.so"; then
        bad "$member from $url is not a 32-bit i386 ELF ($(file -b "$tmp/SLSsteam.so" 2>/dev/null)); refusing to save it as $dst"
        rm -rf "$tmp"
        return 2
    fi
    so_sha="$(sha256sum "$tmp/SLSsteam.so" | cut -d' ' -f1)"
    part="$SLS_DIR/.SLSsteam.so.32.moon64-tmp.$$"
    if ! mkdir -p "$SLS_DIR" "$MOON_DIR" || ! install -m 755 "$tmp/SLSsteam.so" "$part"; then
        rm -rf "$tmp" "$part"
        warn "cannot write $dst; 'moon64 off' will have no 32-bit stack to restore"
        return 1
    fi
    rm -rf "$tmp"
    if [ -e "$dst" ]; then
        rm -f "$part"
        ok "rollback target present: $dst"
        return 0
    fi
    mv -f "$part" "$dst" || { rm -f "$part"; warn "cannot write $dst"; return 1; }
    {
        printf '# Written by moon64 install.sh: where %s came from.\n' "$dst"
        printf 'source=upstream-release\n'
        printf 'version=%s\n' "$version"
        printf 'url=%s\n' "$url"
        printf 'archive_sha256=%s\n' "$got"
        printf 'member=%s\n' "$member"
        printf 'sha256=%s\n' "$so_sha"
        printf 'fetched=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$state" || warn "cannot record the rollback source in $state"
    ok "rollback target: upstream SLSsteam $version (32-bit) saved as $dst"
}

# --- prerequisites ----------------------------------------------------------

# have_header <header> — true when the C++ compiler can include it.
have_header() {
    local cxx="${CXX:-g++}"
    command -v "$cxx" >/dev/null 2>&1 || return 1
    "$cxx" -x c++ -fsyntax-only - >/dev/null 2>&1 <<EOF
#include <$1>
int main(void){return 0;}
EOF
}

# missing_deps <dep...> — set MISSING_DEPS to the deps not on this host.
MISSING_DEPS=()
missing_deps() {
    local d
    MISSING_DEPS=()
    for d in "$@"; do
        case "$d" in
            libcurl-headers) have_header curl/curl.h ;;
            openssl-headers) have_header openssl/evp.h ;;
            g++)             command -v "${CXX:-g++}" >/dev/null 2>&1 ;;
            bsdtar)          command -v 7z >/dev/null 2>&1 || command -v 7za >/dev/null 2>&1 \
                                 || command -v 7zr >/dev/null 2>&1 || command -v bsdtar >/dev/null 2>&1 ;;
            *)               command -v "$d" >/dev/null 2>&1 ;;
        esac || MISSING_DEPS+=("$d")
    done
}

# dep_package <manager> <dep> — the package providing <dep> on that distro family.
dep_package() {
    case "$1:$2" in
        pacman:g++)              printf 'gcc' ;;
        apt-get:g++)             printf 'g++' ;;
        dnf:g++)                 printf 'gcc-c++' ;;
        *:readelf)               printf 'binutils' ;;
        pacman:ldd)              printf 'glibc' ;;
        apt-get:ldd)             printf 'libc-bin' ;;
        dnf:ldd)                 printf 'glibc-common' ;;
        pacman:libcurl-headers)  printf 'curl' ;;
        apt-get:libcurl-headers) printf 'libcurl4-openssl-dev' ;;
        dnf:libcurl-headers)     printf 'libcurl-devel' ;;
        pacman:openssl-headers)  printf 'openssl' ;;
        apt-get:openssl-headers) printf 'libssl-dev' ;;
        dnf:openssl-headers)     printf 'openssl-devel' ;;
        pacman:bsdtar)           printf 'libarchive' ;;
        apt-get:bsdtar)          printf 'libarchive-tools' ;;
        *)                       printf '%s' "$2" ;;
    esac
}

# deps_packages <manager> <dep...> — the packages for those deps, deduplicated.
deps_packages() {
    local pm="$1" d p out=" "
    shift
    for d in "$@"; do
        p="$(dep_package "$pm" "$d")"
        case "$out" in *" $p "*) ;; *) out="$out$p " ;; esac
    done
    out="${out# }"
    printf '%s' "${out% }"
}

# deps_install_cmd <manager> <dep...> — the command a user would run.
deps_install_cmd() {
    local pm="$1" pkgs
    shift
    pkgs="$(deps_packages "$pm" "$@")"
    case "$pm" in
        pacman)  printf 'sudo pacman -S --needed %s' "$pkgs" ;;
        apt-get) printf 'sudo apt-get install -y %s' "$pkgs" ;;
        dnf)     printf 'sudo dnf install -y %s' "$pkgs" ;;
    esac
}

# detect_pkg_manager — pacman, apt-get or dnf ($SLSM_PKG_MANAGER overrides).
detect_pkg_manager() {
    local pm
    case "${SLSM_PKG_MANAGER:-}" in
        pacman|apt-get|dnf) printf '%s' "$SLSM_PKG_MANAGER"; return 0 ;;
    esac
    for pm in pacman apt-get dnf; do
        if command -v "$pm" >/dev/null 2>&1; then printf '%s' "$pm"; return 0; fi
    done
    return 1
}

join_list() {
    local out="" d
    for d in "$@"; do out="${out:+$out, }$d"; done
    printf '%s' "$out"
}

# check_deps <install:0|1> <required...> [-- <optional...>] — report every
# missing prerequisite as one list with the package-manager command. With
# install=1, run that command through `sudo -n`; a sudo that wants a password
# stops here instead of prompting. Returns 1 while a required dep is missing.
check_deps() {
    local install="$1" d pm opt=0
    local -a req=() optional=() miss_req=() miss_opt=() pkgs=() run=()
    shift
    for d in "$@"; do
        if [ "$d" = -- ]; then opt=1
        elif [ "$opt" = 1 ]; then optional+=("$d")
        else req+=("$d")
        fi
    done
    missing_deps "${req[@]}"; miss_req=("${MISSING_DEPS[@]}")
    missing_deps "${optional[@]}"; miss_opt=("${MISSING_DEPS[@]}")
    if [ "${#miss_req[@]}" -eq 0 ] && [ "${#miss_opt[@]}" -eq 0 ]; then
        ok "all prerequisites present"
        return 0
    fi

    [ "${#miss_req[@]}" -eq 0 ] || bad "missing prerequisites: $(join_list "${miss_req[@]}")"
    [ "${#miss_opt[@]}" -eq 0 ] || warn "missing optional: $(join_list "${miss_opt[@]}") (7z or bsdtar unpacks the upstream 32-bit rollback target)"
    if pm="$(detect_pkg_manager)"; then
        dim "  install with: $(deps_install_cmd "$pm" "${miss_req[@]}" "${miss_opt[@]}")"
    else
        dim "  no pacman, apt-get or dnf found; the packages are:"
        for d in pacman apt-get dnf; do
            dim "    $(deps_install_cmd "$d" "${miss_req[@]}" "${miss_opt[@]}")"
        done
    fi
    if [ "$install" != 1 ]; then
        [ "${#miss_req[@]}" -eq 0 ] && return 0
        dim "  or re-run install.sh with --install-deps to have it run that command"
        return 1
    fi

    if [ -z "$pm" ]; then
        bad "--install-deps: no supported package manager (pacman, apt-get, dnf)"
        return 1
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        bad "--install-deps: sudo not found; run the command above as root, then re-run install.sh"
        return 1
    fi
    if ! sudo -n true >/dev/null 2>&1; then
        bad "--install-deps: sudo needs a password, and install.sh will not prompt for one"
        dim "  run the command above yourself, then re-run install.sh"
        return 1
    fi
    read -r -a pkgs <<< "$(deps_packages "$pm" "${miss_req[@]}" "${miss_opt[@]}")"
    case "$pm" in
        pacman)  run=(pacman -S --needed --noconfirm) ;;
        apt-get) run=(apt-get install -y) ;;
        dnf)     run=(dnf install -y) ;;
    esac
    dim "running: sudo -n ${run[*]} ${pkgs[*]}"
    if ! sudo -n "${run[@]}" "${pkgs[@]}"; then
        bad "--install-deps: '${run[*]} ${pkgs[*]}' failed"
        return 1
    fi
    missing_deps "${req[@]}"
    if [ "${#MISSING_DEPS[@]}" -gt 0 ]; then
        bad "still missing after installing ${pkgs[*]}: $(join_list "${MISSING_DEPS[@]}")"
        return 1
    fi
    ok "installed ${pkgs[*]}"
}

# Allow sourcing install.sh in unit tests without executing installer steps.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

with_cloudredirect=0
with_lumen_patch=0
install_deps=0
prebuilt=0
for arg in "$@"; do
    case "$arg" in
        --with-cloudredirect) with_cloudredirect=1 ;;
        --with-lumen-patch)   with_lumen_patch=1 ;;
        --install-deps)       install_deps=1 ;;
        --prebuilt)           prebuilt=1 ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) die "unknown argument: $arg" ;;
    esac
done

[ "$(id -u)" -ne 0 ] || die "run as your desktop user, not root"

[ -f "$HERE/bin/moon64" ] || die "bin/moon64 missing from the checkout"
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
        case "$ldd_out" in
            *GLIBCXX_*'not found'*)
                bad "SLSsteam.so requires a newer libstdc++ (missing GLIBCXX_* version, e.g. GLIBCXX_3.4.32 / GCC 13+)"
                ;;
        esac
        die "SLSsteam.so has unresolved symbols or symbol versions on this host"
    fi
    ok "SLSsteam.so runtime dependencies satisfied ($(printf '%s' "$needed" | tr '\n' ' ' | sed 's/ $//'))"
}

# write_origin_state <staged file> <state file> <source> [key=value...] —
# record where a staged binary came from, for the install summary and
# `moon64 doctor`.
write_origin_state() {
    local f="$1" state="$2" src="$3" kv
    shift 3
    {
        printf '# Written by moon64 install.sh: origin of %s.\n' "${f##*/}"
        printf 'source=%s\n' "$src"
        for kv in "$@"; do printf '%s\n' "$kv"; done
        printf 'sha256=%s\n' "$(sha256sum "$f" | cut -d' ' -f1)"
        printf 'staged=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$state" || warn "cannot write $state"
}

# fetch_prebuilt — stage the prebuilt x86_64 SLSsteam.so published at
# $SLSM_PREBUILT_URL (default SLS64_PREBUILT_URL) as $MOON_DIR/SLSsteam.so.64.
# The release must carry pattern-status.txt next to the library, naming the
# library it was measured on (binary_sha256=), and the same gate as a source
# build applies to it; <url>.sha256 is verified when published. Returns 1 when
# the library or its pattern status cannot be downloaded (the caller builds
# from source instead), 2 when a downloaded file fails a check; then
# PREBUILT_REFUSED names the file and nothing has been staged.
# A verified netsock64.so from the same release is left in $PREBUILT_TMP as
# NETSOCK64_PREBUILT: it is only staged once Steam is stopped (section 2).
fetch_prebuilt() {
    local rc
    PREBUILT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/moon64-prebuilt.XXXXXX")" \
        || { warn "cannot create a temporary directory"; return 1; }
    trap 'rm -rf "$PREBUILT_TMP"' EXIT
    fetch_prebuilt_into "$PREBUILT_TMP"
    rc=$?
    [ -n "$NETSOCK64_PREBUILT" ] || drop_prebuilt_tmp
    return "$rc"
}

drop_prebuilt_tmp() {
    [ -z "${PREBUILT_TMP:-}" ] || rm -rf "$PREBUILT_TMP"
    PREBUILT_TMP=""
    trap - EXIT
}

# status_sha256 <pattern-status.txt> <key> — print its one <key>= value,
# lowercased; fails when the key is absent or repeated.
status_sha256() {
    local key="$2" line trimmed val="" seen=0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
            "$key"=*) seen=$((seen + 1)); val="${trimmed#"$key"=}" ;;
        esac
    done < "$1"
    [ "$seen" -eq 1 ] || return 1
    printf '%s' "${val,,}"
}

# fetch_netsock64_into <tmp> <release dir url> — download the release's
# netsock64.so into <tmp> and check it the way SLSsteam.so is checked: its
# .sha256 when published, the x86-64 ELF class, and the one netsock64_sha256=
# line in <tmp>/res/pattern-status.txt. Returns 0 when it passes, 1 when the
# release has none to download, 2 when a check fails.
fetch_netsock64_into() {
    local tmp="$1" rel="$2" got want="" bound info
    NETSOCK64_URL="$rel/netsock64.so"
    NETSOCK64_SHA_PUBLISHED=no
    if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "$tmp/netsock64.so" "$NETSOCK64_URL" 2>/dev/null; then
        rm -f "$tmp/netsock64.so"
        if status_sha256 "$tmp/res/pattern-status.txt" netsock64_sha256 >/dev/null; then
            warn "cannot download $NETSOCK64_URL, although $rel/pattern-status.txt names one"
        else
            dim "the release has no $NETSOCK64_URL"
        fi
        return 1
    fi

    got="$(sha256sum "$tmp/netsock64.so" | cut -d' ' -f1)"
    if curl -fsSL --connect-timeout 15 --max-time 60 -o "$tmp/netsock64.so.sha256" "$NETSOCK64_URL.sha256" 2>/dev/null; then
        read -r want _ < "$tmp/netsock64.so.sha256" || true
        want="${want,,}"
        if [ "${#want}" -ne 64 ] || [ -n "${want//[0-9a-f]/}" ]; then
            bad "$NETSOCK64_URL.sha256 does not hold a SHA-256 digest"
            return 2
        fi
        if [ "$want" != "$got" ]; then
            bad "prebuilt netsock64.so sha256 $got does not match the published $want"
            return 2
        fi
        ok "prebuilt netsock64.so sha256 matches $NETSOCK64_URL.sha256"
        NETSOCK64_SHA_PUBLISHED=yes
    else
        warn "no $NETSOCK64_URL.sha256 published; netsock64.so is only checked against the netsock64_sha256 in pattern-status.txt"
    fi

    info="$(file -b "$tmp/netsock64.so" 2>/dev/null || true)"
    case "$info" in
        'ELF 64-bit LSB shared object, x86-64'*) ;;
        *) bad "prebuilt netsock64.so is not a 64-bit x86-64 shared object: ${info:-unreadable}"; return 2 ;;
    esac

    if ! bound="$(status_sha256 "$tmp/res/pattern-status.txt" netsock64_sha256)"; then
        bad "$rel/pattern-status.txt must name the netsock64.so released with it with exactly one netsock64_sha256= line"
        return 2
    fi
    if [ "$bound" != "$got" ]; then
        bad "$rel/pattern-status.txt names netsock64.so ${bound:-<empty>}, not the downloaded $got"
        return 2
    fi
    ok "pattern-status.txt names this netsock64.so (netsock64_sha256 $got)"
    return 0
}

fetch_prebuilt_into() {
    local tmp="$1" url="${SLSM_PREBUILT_URL:-${SLS64_PREBUILT_URL:-}}" got want="" bound info verified=no ns_rc
    NETSOCK64_PREBUILT=""
    PREBUILT_REFUSED="SLSsteam.so"
    [ -n "$url" ] || { warn "no prebuilt URL configured (SLSM_PREBUILT_URL)"; return 1; }
    mkdir -p "$tmp/res" || return 1

    dim "downloading the prebuilt SLSsteam.so: $url"
    if ! curl -fsSL --connect-timeout 15 --max-time 300 -o "$tmp/SLSsteam.so" "$url" 2>/dev/null; then
        warn "cannot download $url"
        return 1
    fi
    if ! curl -fsSL --connect-timeout 15 --max-time 60 -o "$tmp/res/pattern-status.txt" "${url%/*}/pattern-status.txt" 2>/dev/null; then
        warn "cannot download ${url%/*}/pattern-status.txt; the pattern gate needs it to accept a prebuilt"
        return 1
    fi

    got="$(sha256sum "$tmp/SLSsteam.so" | cut -d' ' -f1)"
    if curl -fsSL --connect-timeout 15 --max-time 60 -o "$tmp/SLSsteam.so.sha256" "$url.sha256" 2>/dev/null; then
        read -r want _ < "$tmp/SLSsteam.so.sha256" || true
        want="${want,,}"
        if [ "${#want}" -ne 64 ] || [ -n "${want//[0-9a-f]/}" ]; then
            bad "$url.sha256 does not hold a SHA-256 digest"
            return 2
        fi
        if [ "$want" != "$got" ]; then
            bad "prebuilt sha256 $got does not match the published $want"
            return 2
        fi
        ok "prebuilt sha256 matches $url.sha256"
        verified=yes
    else
        warn "no $url.sha256 published; the download is only checked against the binary_sha256 in pattern-status.txt"
    fi

    info="$(file -b "$tmp/SLSsteam.so" 2>/dev/null || true)"
    case "$info" in
        'ELF 64-bit LSB shared object, x86-64'*) ;;
        *) bad "prebuilt SLSsteam.so is not a 64-bit x86-64 shared object: ${info:-unreadable}"; return 2 ;;
    esac

    # The pattern gate trusts the counts in pattern-status.txt, which are only
    # evidence about the library they were measured on. A status file from
    # another build (an older tag, an asset replaced on its own, a latest/
    # download that moved between requests) must not vouch for this one.
    if ! bound="$(status_sha256 "$tmp/res/pattern-status.txt" binary_sha256)"; then
        bad "${url%/*}/pattern-status.txt must name the SLSsteam.so it was measured on with exactly one binary_sha256= line"
        return 2
    fi
    if [ "$bound" != "$got" ]; then
        bad "${url%/*}/pattern-status.txt was measured on SLSsteam.so ${bound:-<empty>}, not on the downloaded $got"
        return 2
    fi
    ok "pattern-status.txt was measured on this SLSsteam.so (binary_sha256 $got)"

    fetch_netsock64_into "$tmp" "${url%/*}"
    ns_rc=$?
    if [ "$ns_rc" -eq 2 ]; then
        PREBUILT_REFUSED="netsock64.so"
        return 2
    fi

    check_pattern_gate "$tmp" || { bad "refusing the prebuilt: its pattern table is incomplete"; return 2; }
    probe_slssteam_deps "$tmp/SLSsteam.so"
    install -m 755 "$tmp/SLSsteam.so" "$MOON_DIR/SLSsteam.so.64" || die "cannot stage SLSsteam.so.64"
    write_origin_state "$MOON_DIR/SLSsteam.so.64" "$MOON_DIR/slsteam64.state" prebuilt "url=$url" "sha256_published=$verified"
    [ "$ns_rc" -ne 0 ] || NETSOCK64_PREBUILT="$tmp/netsock64.so"
    return 0
}

# --- 1. SLSsteam 64-bit: prebuilt release or built from source ------------

# The stack runs the pinned swwayps fork rather than AceSLS's release binary.
# AceSLS's release is 64-bit and works, but it carries 6 feature modules and 17
# patterns; this stack needs the fork's 79 modules (LuaTools stplug-in, Lumen
# CEF-port contract, live appinfo provision, hot reload) and its 61 patterns.
# By default it is built here from source; --prebuilt downloads the project's
# own release build of the same fork instead. See versions.env.
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

# Prerequisites, checked up front and reported as one list. Packages are only
# installed with --install-deps, and then only through a sudo that does not ask
# for a password: the installer never prompts for root or uses it unasked.
# --prebuilt needs no compiler: both binaries come from the release, and the
# toolchain is only asked for if the release cannot be used.
deps_base=(curl gcc readelf file ldd)
deps_prebuilt=(curl readelf file ldd)
deps_build=(g++ make libcurl-headers openssl-headers)
[ -f "$src_dir/Makefile" ] || deps_build+=(git)
deps_opt=()
if [ ! -e "$SLS_DIR/SLSsteam.so.32" ] && { [ ! -f "$SLS_DIR/SLSsteam.so" ] || is_elf64 "$SLS_DIR/SLSsteam.so"; }; then
    deps_opt+=(bsdtar)
fi
if [ "$prebuilt" = 1 ]; then
    check_deps "$install_deps" "${deps_prebuilt[@]}" -- "${deps_opt[@]}" || die "missing prerequisites"
else
    check_deps "$install_deps" "${deps_base[@]}" "${deps_build[@]}" -- "${deps_opt[@]}" || die "missing prerequisites"
fi

sls64_path=""
NETSOCK64_PREBUILT=""
if [ "$prebuilt" = 1 ]; then
    fetch_prebuilt
    case $? in
        0)  sls64_path="prebuilt (${SLSM_PREBUILT_URL:-$SLS64_PREBUILT_URL})" ;;
        2)  die "refusing to stage an unverified prebuilt $PREBUILT_REFUSED; nothing was staged" ;;
        *)  warn "no usable prebuilt SLSsteam.so; building from source instead"
            dim "  a source build links against this host's glibc (the build needs >= 2.38)"
            dim "  and the result only runs on hosts with at least that glibc"
            check_deps "$install_deps" gcc "${deps_build[@]}" || die "missing build prerequisites"
            ;;
    esac
fi

if [ -z "$sls64_path" ]; then
    # Fetch the pinned checkout when it is not present. The fork is a public
    # repo cloned anonymously over HTTPS (the normal path); gh is only used as a
    # convenience when it is already authenticated. GIT_TERMINAL_PROMPT=0 keeps
    # plain git from stopping on a credential prompt in non-interactive runs.
    if [ ! -f "$src_dir/Makefile" ]; then
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
            bad "cannot fetch SLSsteam fork: $slug (network error or missing SLS64_REF '$SLS64_REF')"
            dim "  Option 1: clone it yourself and pass the path:"
            dim "            git clone $SLS64_REPO \$HOME/slsteam-moon-64"
            dim "            SLS64_SRC=\$HOME/slsteam-moon-64 ./install.sh"
            dim "  Option 2: if you use gh, run 'gh auth login' and re-run."
            die "no SLSsteam source available"
        fi
        ok "cloned $slug into $src_dir"
    else
        ok "using source at $src_dir"
    fi

    # Refuse to stage a build whose required pattern table is not complete. A
    # missing required pattern makes Patterns::init() fail and SLSsteam aborts
    # the whole injection, so the client would start completely unpatched --
    # FakeAppIds and everything else silently off. Staging that looks like
    # success and is not.
    check_pattern_gate "$src_dir" || die "refusing to stage an incomplete build"

    command -v pkg-config >/dev/null || dim "note: pkg-config not found; build may still work"

    # Build host floor. The x86_64 source is C++20, and under C++20 glibc's own
    # <cstdlib> redirects strtol/strtoul/strtoll/strtoull to __isoc23_strto*,
    # which first shipped in glibc 2.38. Nothing in the fork calls strtol
    # directly, so there is no source-level opt-out: the build host must be
    # >= 2.38 or the link fails. Say that up front instead of letting make fail
    # eight minutes in.
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
    ( cd "$src_dir" && make ARCH=x86_64 -j"$(nproc 2>/dev/null || echo 2)" ) \
        >"${TMPDIR:-/tmp}/moon64-build.log" 2>&1 \
        || { tail -20 "${TMPDIR:-/tmp}/moon64-build.log" >&2; die "SLSsteam build failed (full log: ${TMPDIR:-/tmp}/moon64-build.log)"; }
    [ -f "$src_dir/bin/SLSsteam.so" ] || die "build produced no bin/SLSsteam.so"
    is_elf64 "$src_dir/bin/SLSsteam.so" || die "built SLSsteam.so is not 64-bit"
    probe_slssteam_deps "$src_dir/bin/SLSsteam.so"
    install -m 755 "$src_dir/bin/SLSsteam.so" "$MOON_DIR/SLSsteam.so.64" || die "cannot stage SLSsteam.so.64"
    src_commit="$(git -C "$src_dir" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    write_origin_state "$MOON_DIR/SLSsteam.so.64" "$MOON_DIR/slsteam64.state" built "src=$src_dir" "commit=$src_commit"
    sls64_path="built from source ($src_dir @ $src_commit)"
fi

# libcurl is dlopen'd, not linked (src/curl.cpp:22), so it never shows up in
# DT_NEEDED and probe_slssteam_deps cannot see it. Without a 64-bit
# libcurl.so.4 on the host the network features degrade to "libcurl
# unavailable" -- provisioning, fixes and updates all stop working.
ldcache="$(ldconfig -p 2>/dev/null || true)"
if ! case "$ldcache" in *libcurl.so.4*) true ;; *) false ;; esac; then
    warn "no libcurl.so.4 on this host; network features will be unavailable"
    dim "  install the 64-bit curl runtime (e.g. curl / libcurl4)"
fi
ok "staged $MOON_DIR/SLSsteam.so.64: $sls64_path"

# Stop Steam only after the gate and build succeed, right before touching live files.
bash "$HERE/bin/moon64" stop-steam || die "cannot stop running Steam; close it manually and re-run"

# Keep the 32-bit original next to the active file, so `moon64 off` can restore
# it without re-downloading. Only the first run needs to save it.
mkdir -p "$SLS_DIR"
if [ -f "$SLS_DIR/SLSsteam.so" ] && ! is_elf64 "$SLS_DIR/SLSsteam.so" && [ ! -f "$SLS_DIR/SLSsteam.so.32" ]; then
    cp -a "$SLS_DIR/SLSsteam.so" "$SLS_DIR/SLSsteam.so.32" || die "cannot save the 32-bit SLSsteam"
    ok "saved the 32-bit SLSsteam.so for rollback"
fi

# A machine that never had upstream SLSsteam has nothing for `moon64 off` to
# go back to. Fetch the pinned 32-bit upstream release instead. No network or
# no unpacker only costs the rollback target; a download that fails its digest
# or ELF-class check stops the install.
if [ ! -e "$SLS_DIR/SLSsteam.so.32" ]; then
    provision_rollback32
    [ "$?" -ne 2 ] || die "refusing to continue with an unverified rollback download"
fi

# --- 2. netsock64 -----------------------------------------------------------
# Staged only now that Steam is stopped: the wrapper puts this file on the
# LD_AUDIT of every launch. The release's verified copy when it has one, else a
# local build, which needs gcc. Without either the install still succeeds, but
# the P2P cert patch is inactive.
netsock64_src="$HERE/patches/netsock64/steamclient_audit64.c"
if [ -n "$NETSOCK64_PREBUILT" ]; then
    install -m 755 "$NETSOCK64_PREBUILT" "$MOON_DIR/netsock64.so" || die "cannot stage netsock64.so"
    cmp -s "$NETSOCK64_PREBUILT" "$MOON_DIR/netsock64.so" || die "staged netsock64.so differs from the verified download"
    write_origin_state "$MOON_DIR/netsock64.so" "$MOON_DIR/netsock64.state" prebuilt \
        "url=$NETSOCK64_URL" "sha256_published=$NETSOCK64_SHA_PUBLISHED"
    drop_prebuilt_tmp
    netsock64_path="prebuilt ($NETSOCK64_URL)"
    ok "staged $MOON_DIR/netsock64.so: $netsock64_path"
elif [ -f "$netsock64_src" ] && command -v gcc >/dev/null 2>&1; then
    gcc -O2 -Wall -Wextra -shared -fPIC \
        -o "$MOON_DIR/netsock64.so" "$netsock64_src" -ldl || die "netsock64 build failed"
    write_origin_state "$MOON_DIR/netsock64.so" "$MOON_DIR/netsock64.state" built "src=$netsock64_src"
    netsock64_path="built from $netsock64_src"
    ok "built $MOON_DIR/netsock64.so"
else
    if [ -f "$netsock64_src" ]; then why="gcc is not installed to build it"; else why="this copy of moon64 has no patches/netsock64 to build it from"; fi
    [ "$prebuilt" = 1 ] && why="the release has no netsock64.so and $why"
    if [ -f "$MOON_DIR/netsock64.so" ]; then
        warn "$why; keeping the netsock64.so from an earlier install"
        netsock64_path="kept from an earlier install"
    else
        warn "$why: the P2P cert patch will be inactive"
        dim "  this is a degraded feature, not a failed install: Steam, SLSsteam and"
        dim "  LuaTools work, but co-op joins that need peer-to-peer (Satisfactory, REPO) fail"
        netsock64_path="none (the P2P cert patch is inactive)"
    fi
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
# Public repos clone anonymously over HTTPS; gh is used when already
# authenticated, and GIT_TERMINAL_PROMPT=0 avoids hanging on prompts.
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
ok "SLSsteam.so.64: $sls64_path"
ok "netsock64.so: $netsock64_path"
dim "verify:  $MOON_DIR/moon64 doctor"
dim "switch:  $MOON_DIR/moon64 on     (undo: $MOON_DIR/moon64 off)"
