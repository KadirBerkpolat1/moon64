#!/usr/bin/env bash
# get.sh - install moon64 from its published binaries:
#
#   curl -fsSL https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/get.sh | bash
#
# Downloads install.sh, bin/moon64, bin/wrapper.64.sh and versions.env with curl
# into a temporary directory and runs `install.sh --prebuilt` from there, which
# downloads the prebuilt SLSsteam.so and netsock64.so: no git, no compiler.
# It stages ~/.local/share/moon64 and activates nothing; `moon64 on` does that.
#
# Everything below is inside main(), so bash has read the whole script before
# it runs any of it: a download cut short runs nothing, and no command can read
# the rest of this script from stdin when it arrives through a pipe.

GET_REPO_RAW="https://raw.githubusercontent.com/KadirBerkpolat1/moon64"
GET_FILES=(install.sh bin/moon64 bin/wrapper.64.sh versions.env)

get_usage() {
    cat <<'EOF'
Usage: curl -fsSL https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/get.sh | bash
       curl -fsSL .../get.sh | bash -s -- [--install-deps | --dry-run | --help]
       bash get.sh [--install-deps | --dry-run | --help]

  --install-deps   let install.sh install missing prerequisites with the distro
                   package manager, through a sudo that does not ask for a
                   password (it never prompts)
  --dry-run        print what would be downloaded and run; change nothing
  --help           this text

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
    if [ "$GET_INSTALLING" = 1 ]; then
        get_restore
    fi
    [ -z "$GET_TMP" ] || rm -rf "$GET_TMP"
}

main() {
    set -uo pipefail
    local dry_run=0 arg ref base moon_dir f url rc log entry rerun=""
    local -a pass=()
    GET_TMP=""
    GET_INSTALLING=0
    GET_HAD_DIR=0

    for arg in "$@"; do
        case "$arg" in
            --help|-h)      get_usage; return 0 ;;
            --dry-run)      dry_run=1 ;;
            --install-deps) pass+=(--install-deps) ;;
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
        for f in "${GET_FILES[@]}"; do get_say "$base/$f"; done
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
    for f in "${GET_FILES[@]}"; do
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

    printf 'moon64: running install.sh --prebuilt%s\n\n' "${pass[*]:+ ${pass[*]}}"
    log="$GET_TMP/install.log"
    GET_INSTALLING=1
    ( cd "$GET_TMP/src" && bash ./install.sh --prebuilt "${pass[@]}" ) </dev/null 2>&1 | tee "$log"
    rc="${PIPESTATUS[0]}"
    if [ "$rc" -eq 0 ]; then
        GET_INSTALLING=0
        printf '\nmoon64 is staged in %s from %s; nothing is active yet.\n' "$moon_dir" "$base"
        printf 'next:  %s/moon64 doctor\n' "$moon_dir"
        printf '       %s/moon64 on      (with Steam closed; undo: %s/moon64 off)\n' "$moon_dir" "$moon_dir"
        return 0
    fi

    printf '\n' >&2
    get_fail "install.sh failed (exit $rc)"
    case "$(cat "$log" 2>/dev/null)" in
        *"missing prerequisites"*|*"missing build prerequisites"*)
            if [ "${#pass[@]}" -eq 0 ]; then
                [ -z "${MOON64_REF:-}" ] || rerun="$rerun MOON64_REF=$(printf '%q' "$MOON64_REF")"
                [ -z "${MOON64_DIR:-}" ] || rerun="$rerun MOON64_DIR=$(printf '%q' "$MOON64_DIR")"
                [ -z "${SLSM_PREBUILT_URL:-}" ] || rerun="$rerun SLSM_PREBUILT_URL=$(printf '%q' "$SLSM_PREBUILT_URL")"
                get_fail "install the packages listed above and run this again, or let install.sh"
                get_fail "install them (it uses 'sudo -n' and stops if sudo wants a password):"
                get_fail "  curl -fsSL $base/get.sh |$rerun bash -s -- --install-deps"
            fi
            ;;
    esac
    return "$rc"
}

main "$@"
