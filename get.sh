#!/usr/bin/env bash
# get.sh - install moon64 from its published binaries:
#
#   curl -fsSL https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/get.sh | bash
#
# Downloads install.sh, bin/moon64, bin/wrapper.64.sh, versions.env and the
# netsock64 source with curl into a temporary directory and runs
# `install.sh --prebuilt` from there: SLSsteam.so (and netsock64.so, when the
# release has one) come prebuilt, so no git and no compiler are needed. Without
# a prebuilt netsock64.so, install.sh builds it from that source if gcc is
# installed. With --with-cloudredirect it also fetches bin/build-cloudredirect.sh
# and passes the flag on, so the 64-bit CloudRedirect pair is built and staged
# too (needs git, cmake, g++, make and perl). It stages ~/.local/share/moon64 and activates
# nothing; `moon64 on` does that.
#
# Everything below is inside main(), so bash has read the whole script before
# it runs any of it: a download cut short runs nothing, and no command can read
# the rest of this script from stdin when it arrives through a pipe.

GET_REPO_RAW="https://raw.githubusercontent.com/KadirBerkpolat1/moon64"
GET_FILES=(install.sh bin/moon64 bin/wrapper.64.sh versions.env patches/netsock64/steamclient_audit64.c)

get_usage() {
    cat <<'EOF'
Usage: curl -fsSL https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/get.sh | bash
       curl -fsSL .../get.sh | bash -s -- [--install-deps] [--with-cloudredirect] [--dry-run | --help]
       bash get.sh [--install-deps] [--with-cloudredirect] [--dry-run | --help]

  --install-deps         let install.sh install missing prerequisites with the
                         distro package manager, through a sudo that does not
                         ask for a password (it never prompts)
  --with-cloudredirect   also build and stage the 64-bit CloudRedirect pair
                         (cloud saves); needs git, cmake, g++, make and perl
  --dry-run              print what would be downloaded and run; change nothing
  --help                 this text

Environment:
  MOON64_REF          git ref of moon64 to install from (default: main)
  MOON64_DIR          where moon64 is staged (default: ~/.local/share/moon64)
  SLSM_PREBUILT_URL   prebuilt SLSsteam.so; netsock64.so, pattern-status.txt and
                      the .sha256 files are taken from the same directory
                      (default: pinned in versions.env)

Nothing is activated: run `moon64 doctor`, then `moon64 on` with Steam closed.
EOF
}

get_say()  { printf '  %s\n' "$*"; }
get_fail() { printf 'moon64 get.sh: %s\n' "$*" >&2; }

# get_restore - put the moon64 directory back the way this run found it.
get_restore() {
    local entry
    if [ "$GET_HAD_DIR" = 0 ]; then
        [ -e "$GET_MOON_DIR" ] || return 0
        rm -rf "$GET_MOON_DIR"
        get_fail "removed $GET_MOON_DIR, which this run had created"
        return 0
    fi
    for entry in "$GET_MOON_DIR"/* "$GET_MOON_DIR"/.[!.]* "$GET_MOON_DIR"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        [ "${entry##*/}" = src ] && continue
        rm -rf "$entry"
    done
    if cp -a "$GET_TMP/moon64-before/." "$GET_MOON_DIR/"; then
        get_fail "restored $GET_MOON_DIR to what it was before this run"
    else
        get_fail "could not restore $GET_MOON_DIR; its previous contents are in $GET_TMP/moon64-before"
        GET_TMP=""
    fi
}

get_cleanup() {
    # Idempotent: the EXIT trap and the explicit call at the bottom of this
    # script can both run it (bash 5.3 never runs an EXIT trap at a natural
    # EOF when the script arrives on stdin, so that call is the one that
    # counts; where the trap does fire, the second pass is a no-op).
    if [ "${GET_INSTALLING:-0}" = 1 ]; then
        GET_INSTALLING=0
        get_restore
        if [ "${GET_HAD_SLS_DIR:-1}" = 0 ] && [ -e "${GET_SLS_DIR:-}" ]; then
            rm -rf "$GET_SLS_DIR"
            get_fail "removed $GET_SLS_DIR, which this run had created"
        fi
    fi
    [ -z "${GET_TMP:-}" ] || { local t="$GET_TMP"; GET_TMP=""; rm -rf "$t"; }
}

# get_cert_patch <moon dir> - one or two lines on the P2P cert patch, from the
# netsock64.so the wrapper will put on LD_AUDIT and install.sh's record of it.
get_cert_patch() {
    local so="$1/netsock64.so" state="$1/netsock64.state" key val src="" sha="" got=""
    if [ ! -f "$so" ]; then
        printf 'P2P cert patch: INACTIVE - co-op joins that need peer-to-peer (Satisfactory, REPO) will fail.\n'
        if [ -n "${SLSM_PREBUILT_URL:-}" ]; then
            printf '                install gcc and run this again, or run it without SLSM_PREBUILT_URL: the latest release ships netsock64.so prebuilt.\n'
        else
            printf '                install gcc and run this again to build it from the downloaded source.\n'
        fi
        return 0
    fi
    if [ -f "$state" ]; then
        while IFS='=' read -r key val; do
            case "$key" in
                source) src="$val" ;;
                sha256) sha="$val" ;;
            esac
        done < "$state"
    fi
    if [ -n "$sha" ]; then
        got="$(sha256sum "$so" 2>/dev/null | cut -d' ' -f1)"
        if [ -n "$got" ] && [ "$sha" = "$got" ]; then
            case "$src" in
                prebuilt)
                    printf 'P2P cert patch: active once you run moon64 on (netsock64.so from the release)\n'
                    return 0
                    ;;
                built)
                    printf 'P2P cert patch: active once you run moon64 on (netsock64.so built from source)\n'
                    return 0
                    ;;
            esac
        else
            printf 'P2P cert patch: UNVERIFIED - netsock64.so changed since install.sh recorded it; re-run the installer to restage it.\n'
            printf '                co-op joins that need peer-to-peer will fail if that file is not the cert patch.\n'
            return 0
        fi
    fi
    printf 'P2P cert patch: UNVERIFIED - no install record for netsock64.so; re-run the installer to verify it.\n'
    printf '                co-op joins that need peer-to-peer will fail if that file is not the cert patch.\n'
}

main() {
    set -uo pipefail
    local dry_run=0 deps=0 cr_arg="" arg ref base moon_dir f url rc log entry rerun=""
    local -a pass=() files=("${GET_FILES[@]}")
    GET_TMP=""
    GET_INSTALLING=0
    GET_HAD_DIR=0

    for arg in "$@"; do
        case "$arg" in
            --help|-h)      get_usage; return 0 ;;
            --dry-run)      dry_run=1 ;;
            --install-deps) pass+=(--install-deps); deps=1 ;;
            --with-cloudredirect)
                pass+=(--with-cloudredirect); files+=(bin/build-cloudredirect.sh)
                cr_arg=" --with-cloudredirect" ;;
            *) get_fail "unknown argument: $arg (see --help)"; return 2 ;;
        esac
    done

    ref="${MOON64_REF:-main}"
    case "$ref" in
        ''|-*|*[!A-Za-z0-9._/-]*|*..*)
            get_fail "MOON64_REF '$ref' is not a branch, tag or commit name"; return 2 ;;
    esac
    base="$GET_REPO_RAW/$ref"
    [ -n "${HOME:-}" ] || { get_fail "HOME is not set"; return 1; }
    moon_dir="${MOON64_DIR:-$HOME/.local/share/moon64}"

    if [ "$dry_run" = 1 ]; then
        printf 'moon64 get.sh --dry-run: nothing will be downloaded or changed.\n'
        printf 'would download with curl, from %s:\n' "$base"
        for f in "${files[@]}"; do get_say "$base/$f"; done
        printf 'would run:  install.sh --prebuilt%s\n' "${pass[*]:+ ${pass[*]}}"
        get_say "SLSsteam.so: ${SLSM_PREBUILT_URL:-the default pinned in versions.env at $ref}"
        get_say "netsock64.so, pattern-status.txt, *.sha256: from the same release directory"
        get_say "staged into: $moon_dir"
        get_say "activated: nothing (run 'moon64 on' yourself)"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        get_fail "curl is not installed; install curl and run this again"
        return 1
    fi
    if [ "$(id -u)" -eq 0 ]; then
        get_fail "run this as your desktop user, not root"
        return 1
    fi

    GET_TMP="$(mktemp -d "${TMPDIR:-/tmp}/moon64-get.XXXXXX")" \
        || { get_fail "cannot create a temporary directory"; return 1; }
    trap get_cleanup EXIT
    trap 'exit 130' INT TERM

    printf 'moon64: downloading the installer from %s\n' "$base"
    for f in "${files[@]}"; do
        url="$base/$f"
        mkdir -p "$GET_TMP/src/$(dirname "$f")" || { get_fail "cannot write to $GET_TMP"; return 1; }
        curl -fsSL --connect-timeout 15 --max-time 60 -o "$GET_TMP/src/$f" "$url"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            get_fail "cannot download $url (curl exit $rc); nothing was installed"
            return 1
        fi
        get_say "$f  sha256 $(sha256sum "$GET_TMP/src/$f" | cut -d' ' -f1)"
    done

    if [ -e "$moon_dir" ]; then
        GET_HAD_DIR=1
        mkdir -p "$GET_TMP/moon64-before" || { get_fail "cannot write to $GET_TMP"; return 1; }
        for entry in "$moon_dir"/* "$moon_dir"/.[!.]* "$moon_dir"/..?*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            [ "${entry##*/}" = src ] && continue
            cp -a "$entry" "$GET_TMP/moon64-before/" \
                || { get_fail "cannot back up $entry before installing"; return 1; }
        done
    fi
    GET_MOON_DIR="$moon_dir"
    GET_SLS_DIR="$HOME/.local/share/SLSsteam"
    GET_HAD_SLS_DIR=0
    [ ! -e "$GET_SLS_DIR" ] || GET_HAD_SLS_DIR=1

    printf 'moon64: running install.sh --prebuilt%s\n\n' "${pass[*]:+ ${pass[*]}}"
    log="$GET_TMP/install.log"
    GET_INSTALLING=1
    ( cd "$GET_TMP/src" && bash ./install.sh --prebuilt "${pass[@]}" ) </dev/null 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
    if [ "$rc" -eq 0 ]; then
        GET_INSTALLING=0
        printf '\nmoon64 is staged in %s from %s; nothing is active yet.\n' "$moon_dir" "$base"
        get_cert_patch "$moon_dir"
        printf 'next:  %s/moon64 doctor\n' "$moon_dir"
        printf '       %s/moon64 on      (with Steam closed; undo: %s/moon64 off)\n' "$moon_dir" "$moon_dir"
        return 0
    fi

    printf '\n' >&2
    get_fail "install.sh failed (exit $rc)"
    case "$(cat "$log" 2>/dev/null)" in
        *"missing prerequisites"*|*"missing build prerequisites"*)
            if [ "$deps" = 0 ]; then
                [ -z "${MOON64_REF:-}" ] || rerun="$rerun MOON64_REF=$(printf '%q' "$MOON64_REF")"
                [ -z "${MOON64_DIR:-}" ] || rerun="$rerun MOON64_DIR=$(printf '%q' "$MOON64_DIR")"
                [ -z "${SLSM_PREBUILT_URL:-}" ] || rerun="$rerun SLSM_PREBUILT_URL=$(printf '%q' "$SLSM_PREBUILT_URL")"
                get_fail "install the packages listed above and run this again, or let install.sh"
                get_fail "install them (it uses 'sudo -n' and stops if sudo wants a password):"
                get_fail "  curl -fsSL $base/get.sh |$rerun bash -s -- --install-deps$cr_arg"
            fi
            ;;
    esac
    return "$rc"
}

main "$@"
rc=$?
get_cleanup
exit "$rc"
