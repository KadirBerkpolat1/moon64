#!/usr/bin/env bash
# Sandbox test for get.sh, run the way `curl ... | bash` runs it: the script
# arrives on stdin (`bash -s`), so $0 is `bash` and BASH_SOURCE is empty. curl
# is a stub that serves the real URLs (raw.githubusercontent.com and the
# release's latest/download) from local fixtures and refuses any other host.
# PATH has no git, gcc, cc, g++, c++, make or clang.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { printf 'PASS [%s]\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL [%s]: %s\n' "$1" "$2" >&2; FAIL=$((FAIL + 1)); }

assert_rc() {
    local label="$1" expected="$2" actual="$3" out="${4:-}"
    if [ "$expected" -eq "$actual" ]; then pass "$label (rc=$actual)"; else fail "$label" "expected rc=$expected, got rc=$actual"$'\n'"$out"; fi
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label" "expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"; fi
}

assert_contains() {
    local label="$1" substr="$2" text="$3"
    case "$text" in
        *"$substr"*) pass "$label" ;;
        *) fail "$label" "missing $(printf '%q' "$substr") in:"$'\n'"$text" ;;
    esac
}

assert_not_contains() {
    local label="$1" substr="$2" text="$3"
    case "$text" in
        *"$substr"*) fail "$label" "unexpected $(printf '%q' "$substr") in:"$'\n'"$text" ;;
        *) pass "$label" ;;
    esac
}

assert_same() {
    if cmp -s "$2" "$3"; then pass "$1"; else fail "$1" "$2 differs from $3"; fi
}

assert_absent() {
    if [ ! -e "$2" ] && [ ! -L "$2" ]; then pass "$1"; else fail "$1" "unexpected file: $2"; fi
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

# snapshot <dir> — every file and symlink under <dir> with its content hash.
snapshot() {
    local root="$1" p
    [ -d "$root" ] || { printf 'ABSENT\n'; return 0; }
    ( cd "$root" && find . \( -type f -o -type l \) -print | LC_ALL=C sort ) | while IFS= read -r p; do
        if [ -L "$root/$p" ]; then
            printf 'L %s -> %s\n' "$p" "$(readlink "$root/$p")"
        else
            printf 'F %s %s\n' "$p" "$(sha "$root/$p")"
        fi
    done
}

make_so() { printf 'void %s(void) {}\n' "$1" | gcc -shared -fPIC -x c - -o "$2"; }
make_elf32() {
    mkdir -p "$(dirname "$1")"
    { printf '\177ELF\001\001\001'; head -c 9 /dev/zero; printf '\003\000\003\000\001\000\000\000'; head -c 28 /dev/zero; } > "$1"
}

# mirror_path <name...> — $PATH without any compiler, git or make, nor the
# names given. Directories holding one are mirrored without it; the others are
# kept as is (version-manager shims refuse to run through a symlink).
is_toolchain() {
    case "$1" in
        git|gcc|cc|g++|c++|make|gmake|clang|clang++|tcc|*-gcc|*-g++|*-c++|*-cc|gcc-[0-9]*|g++-[0-9]*|*-gcc-[0-9]*|clang-[0-9]*) return 0 ;;
    esac
    return 1
}
NO_TOOLCHAIN=(git gcc cc g++ c++ make clang clang++ tcc)
mirror_path() {
    local out="" d f t hit m x
    local -a dirs drop=("${NO_TOOLCHAIN[@]}" "$@")
    IFS=: read -ra dirs <<< "$PATH"
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        hit=0
        for t in "${drop[@]}"; do [ -e "$d/$t" ] && hit=1; done
        if [ "$hit" = 1 ]; then
            m="$(mktemp -d "$TMP_ROOT/path.XXXXXX")"
            for f in "$d"/*; do
                is_toolchain "${f##*/}" && continue
                for x in "$@"; do [ "${f##*/}" = "$x" ] && continue 2; done
                [ -x "$f" ] && ln -s "$f" "$m/${f##*/}"
            done
            d="$m"
        fi
        out="${out:+$out:}$d"
    done
    printf '%s' "$out"
}
NOCC="$(mirror_path)"
NOCC_NO_READELF="$(mirror_path readelf)"

# --- fixtures ----------------------------------------------------------------
RAW="$TMP_ROOT/raw"
FILES=(install.sh bin/moon64 bin/wrapper.64.sh versions.env patches/netsock64/steamclient_audit64.c)
for ref in main v-test broken; do
    for f in "${FILES[@]}"; do
        mkdir -p "$RAW/$ref/$(dirname "$f")"
        cp "$REPO_ROOT/$f" "$RAW/$ref/$f"
    done
done
rm -f "$RAW/broken/bin/wrapper.64.sh"

STATUS=$'arch=x86_64\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=ready'
# make_release <name> [variant] — a complete release: both libraries, their
# .sha256 files and a pattern-status.txt binding both. Variants: mismatch
# (netsock64 bound to the wrong digest), absent (no netsock64.so, no .sha256,
# no binding line: what v1.0.0 publishes), bound-missing (the binding line,
# but no netsock64.so or .sha256).
make_release() {
    local d="$TMP_ROOT/rel-$1" ns
    mkdir -p "$d"
    make_so "sls_$1" "$d/SLSsteam.so"
    make_so "netsock_$1" "$d/netsock64.so"
    printf '%s  SLSsteam.so\n' "$(sha "$d/SLSsteam.so")" > "$d/SLSsteam.so.sha256"
    printf '%s  netsock64.so\n' "$(sha "$d/netsock64.so")" > "$d/netsock64.so.sha256"
    ns="netsock64_sha256=$(sha "$d/netsock64.so")"$'\n'
    case "${2:-}" in
        mismatch) ns="netsock64_sha256=$(sha "$d/SLSsteam.so")"$'\n' ;;
        absent) ns="" ;;
    esac
    printf '%s\nbinary_sha256=%s\n%s' "$STATUS" "$(sha "$d/SLSsteam.so")" "$ns" > "$d/pattern-status.txt"
    case "${2:-}" in absent|bound-missing) rm -f "$d/netsock64.so" "$d/netsock64.so.sha256" ;; esac
    printf '%s' "$d"
}
REL="$(make_release default)"
REL_OTHER="$(make_release other)"
REL_BAD="$(make_release bad mismatch)"
REL_ABSENT="$(make_release absent absent)"
REL_BOUND_MISSING="$(make_release bound_missing bound-missing)"

REAL_CURL="$(command -v curl)"
STUB="$TMP_ROOT/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
# Serves the real URLs from fixtures; any other host is unreachable.
args=()
for a in "$@"; do
    case "$a" in
        https://raw.githubusercontent.com/KadirBerkpolat1/moon64/*)
            printf '%s\n' "$a" >> "$GETSH_CURL_LOG"
            a="file://$GETSH_RAW/${a#https://raw.githubusercontent.com/KadirBerkpolat1/moon64/}" ;;
        https://github.com/KadirBerkpolat1/slsteam-moon-64/releases/latest/download/*)
            printf '%s\n' "$a" >> "$GETSH_CURL_LOG"
            a="file://$GETSH_REL/${a##*/}" ;;
        file://*)
            printf '%s\n' "$a" >> "$GETSH_CURL_LOG" ;;
        http://*|https://*)
            printf '%s\n' "$a" >> "$GETSH_CURL_LOG"
            printf 'curl: (6) Could not resolve host\n' >&2
            exit 6 ;;
    esac
    args+=("$a")
done
exec "$GETSH_REAL_CURL" "${args[@]}"
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/systemctl"
cat > "$STUB/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GETSH_SUDO_LOG"
exit 1
SH
chmod +x "$STUB/curl" "$STUB/systemctl" "$STUB/sudo"

# make_sandbox <name> [clean] — a throwaway HOME. By default it has a 32-bit
# SLSsteam installed (saved as the rollback target, nothing downloaded); clean
# means a machine without one.
make_sandbox() {
    local sb="$TMP_ROOT/$1"
    mkdir -p "$sb/home/.steam" "$sb/home/.local/share/Steam/steamrt64" "$sb/tmp" "$sb/proc" "$sb/cwd"
    [ "${2:-}" = clean ] || make_elf32 "$sb/home/.local/share/SLSsteam/SLSsteam.so"
    printf '%s' "$sb"
}

# pipe_get <sb> [args...] — run get.sh the way `curl ... | bash -s -- args` does:
# its text arrives on bash's stdin through a pipe, from an unrelated directory,
# with only $GETSH_ENV (extra NAME=value words) added. GETSH_RELEASE picks the
# release the latest/download URLs serve (default $REL).
GETSH_ENV=()
pipe_get() {
    local sb="$1" h="$1/home"
    shift
    : > "$sb/curl.log"
    cat "$REPO_ROOT/get.sh" | ( cd "$sb/cwd" && env -i \
        PATH="$STUB:${GETSH_PATH:-$NOCC}" HOME="$h" USER="${USER:-user}" TERM=dumb \
        TMPDIR="$sb/tmp" XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
        XDG_DATA_DIRS="$sb/none" SLSM_PROC_ROOT="$sb/proc" LUMEN_FIX_INSTALLS_DIR="$sb/none" \
        SLSM_PKG_MANAGER=pacman SLSM_SLS32_URL="${GETSH_SLS32_URL:-file://$sb/no-rollback-download.7z}" \
        GETSH_CURL_LOG="$sb/curl.log" GETSH_SUDO_LOG="$sb/sudo.log" GETSH_RAW="$RAW" \
        GETSH_REL="${GETSH_RELEASE:-$REL}" GETSH_REAL_CURL="$REAL_CURL" \
        "${GETSH_ENV[@]}" \
        bash -s -- "$@" )
}

raw_urls() { grep '^https://raw.githubusercontent.com/' "$1/curl.log" 2>/dev/null; }
expected_raw() {
    local f
    for f in "${FILES[@]}"; do printf 'https://raw.githubusercontent.com/KadirBerkpolat1/moon64/%s/%s\n' "$1" "$f"; done
}

# --- (0) the PATH really has no toolchain -----------------------------------
for t in "${NO_TOOLCHAIN[@]}"; do
    found="$(env PATH="$STUB:$NOCC" bash -c "command -v $t" 2>/dev/null)"
    if [ -z "$found" ]; then pass "0: $t is not on PATH"; else fail "0: $t is not on PATH" "found $found"; fi
done

# --- (a) --help ----------------------------------------------------------------
sb="$(make_sandbox a)"
out="$(pipe_get "$sb" --help 2>&1)"; rc=$?
assert_rc "a1: --help through the pipe exits 0" 0 "$rc" "$out"
assert_contains "a1: shows the one-liner" "curl -fsSL https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/get.sh | bash" "$out"
out="$(bash "$REPO_ROOT/get.sh" --help 2>&1)"; rc=$?
assert_rc "a2: bash get.sh --help exits 0" 0 "$rc" "$out"
assert_contains "a2: documents --install-deps" "--install-deps" "$out"
out="$(pipe_get "$sb" --bogus 2>&1)"; rc=$?
assert_rc "a3: an unknown argument is refused" 2 "$rc" "$out"
assert_contains "a3: and named" "unknown argument: --bogus" "$out"

# --- (b) --dry-run changes nothing ---------------------------------------------
sb="$(make_sandbox b)"
before="$(snapshot "$sb")"
out="$(pipe_get "$sb" --dry-run 2>&1)"; rc=$?
assert_rc "b1: --dry-run exits 0" 0 "$rc" "$out"
assert_contains "b1: prints the five URLs" "$(expected_raw main | sed 's/^/  /')" "$out"
assert_contains "b1: prints the installer command" "would run:  install.sh --prebuilt" "$out"
assert_contains "b1: prints the target" "staged into: $sb/home/.local/share/moon64" "$out"
assert_eq "b1: curl never ran" "" "$(cat "$sb/curl.log")"
rm -f "$sb/curl.log"
assert_eq "b1: the sandbox is byte-identical" "$before" "$(snapshot "$sb")"

# --- (c) the one-liner on a clean machine -----------------------------------
sb="$(make_sandbox c)"
MD="$sb/home/.local/share/moon64"
out="$(pipe_get "$sb" 2>&1)"; rc=$?
assert_rc "c1: get.sh installs with no git or compiler on PATH" 0 "$rc" "$out"
assert_eq "c1: fetched exactly the five files, from main" "$(expected_raw main)" "$(raw_urls "$sb")"
assert_contains "c1: says where it downloads from" "moon64: downloading the installer from https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main" "$out"
assert_contains "c1: prints each file's digest" "bin/moon64  sha256 $(sha "$REPO_ROOT/bin/moon64")" "$out"
assert_contains "c1: runs the installer with --prebuilt" "moon64: running install.sh --prebuilt" "$out"
assert_contains "c1: SLSsteam.so from the default release" "SLSsteam.so.64: prebuilt (https://github.com/KadirBerkpolat1/slsteam-moon-64/releases/latest/download/SLSsteam.so)" "$out"
assert_contains "c1: netsock64.so from the same release" "netsock64.so: prebuilt (https://github.com/KadirBerkpolat1/slsteam-moon-64/releases/latest/download/netsock64.so)" "$out"
assert_same "c1: SLSsteam.so.64 staged" "$REL/SLSsteam.so" "$MD/SLSsteam.so.64"
assert_same "c1: netsock64.so staged" "$REL/netsock64.so" "$MD/netsock64.so"
assert_same "c1: moon64 installed" "$REPO_ROOT/bin/moon64" "$MD/moon64"
assert_same "c1: wrapper installed" "$REPO_ROOT/bin/wrapper.64.sh" "$MD/wrapper.64.sh"
assert_contains "c1: hands over to the user" "next:  $MD/moon64 doctor" "$out"
assert_contains "c1: activates nothing" "nothing is active yet" "$out"
assert_contains "c1: close: cert patch active, from the release" $'nothing is active yet.\nP2P cert patch: active once you run moon64 on (netsock64.so from the release)\n' "$out"
assert_not_contains "c1: close: not inactive" "P2P cert patch: INACTIVE" "$out"
assert_absent "c1: no desktop override" "$sb/home/.local/share/applications/steam.desktop"
assert_absent "c1: no sudo" "$sb/sudo.log"
assert_eq "c1: temporary files removed" "" "$(ls -A "$sb/tmp")"

# --- (d) MOON64_REF, MOON64_DIR and SLSM_PREBUILT_URL are respected -----------
sb="$(make_sandbox d)"
GETSH_ENV=(MOON64_REF=v-test MOON64_DIR="$sb/custom" SLSM_PREBUILT_URL="file://$REL_OTHER/SLSsteam.so")
out="$(pipe_get "$sb" 2>&1)"; rc=$?
GETSH_ENV=()
assert_rc "d1: succeeds" 0 "$rc" "$out"
assert_eq "d1: fetched the five files at MOON64_REF" "$(expected_raw v-test)" "$(raw_urls "$sb")"
assert_same "d1: staged into MOON64_DIR" "$REL_OTHER/netsock64.so" "$sb/custom/netsock64.so"
assert_absent "d1: not into the default" "$sb/home/.local/share/moon64"
assert_contains "d1: from SLSM_PREBUILT_URL" "SLSsteam.so.64: prebuilt (file://$REL_OTHER/SLSsteam.so)" "$out"
GETSH_ENV=(MOON64_REF='main;rm')
out="$(pipe_get "$sb" 2>&1)"; rc=$?
GETSH_ENV=()
assert_rc "d2: a malformed MOON64_REF is refused" 2 "$rc" "$out"

# --- (e) a file missing from the repo: specific failure, nothing installed ----
sb="$(make_sandbox e)"
GETSH_ENV=(MOON64_REF=broken)
out="$(pipe_get "$sb" 2>&1)"; rc=$?
GETSH_ENV=()
assert_rc "e1: fails" 1 "$rc" "$out"
assert_contains "e1: names the file and curl's exit" "cannot download https://raw.githubusercontent.com/KadirBerkpolat1/moon64/broken/bin/wrapper.64.sh (curl exit 37); nothing was installed" "$out"
assert_not_contains "e1: never ran the installer" "running install.sh" "$out"
assert_absent "e1: no moon64 directory" "$sb/home/.local/share/moon64"
assert_eq "e1: temporary files removed" "" "$(ls -A "$sb/tmp")"

# --- (f) the installer refuses the release: nothing left behind ---------------
sb="$(make_sandbox f)"
GETSH_ENV=(SLSM_PREBUILT_URL="file://$REL_BAD/SLSsteam.so")
out="$(pipe_get "$sb" 2>&1)"; rc=$?
GETSH_ENV=()
assert_rc "f1: fails with install.sh's exit" 1 "$rc" "$out"
assert_contains "f1: install.sh says why" "refusing to stage an unverified prebuilt netsock64.so; nothing was staged" "$out"
assert_contains "f1: get.sh says it failed" "moon64 get.sh: install.sh failed (exit 1)" "$out"
assert_absent "f1: the moon64 directory install.sh created is gone" "$sb/home/.local/share/moon64"

# A failure after install.sh had staged files: a rollback download that fails
# its digest stops it after SLSsteam.so.64 is in place.
sb="$(make_sandbox f2 clean)"
printf 'not the pinned release\n' > "$sb/wrong.7z"
GETSH_SLS32_URL="file://$sb/wrong.7z"
out="$(GETSH_SLS32_URL="$GETSH_SLS32_URL" pipe_get "$sb" 2>&1)"; rc=$?
assert_rc "f2: fails" 1 "$rc" "$out"
assert_contains "f2: after staging" "staged $sb/home/.local/share/moon64/SLSsteam.so.64" "$out"
assert_contains "f2: says it cleaned up" "removed $sb/home/.local/share/moon64, which this run had created" "$out"
assert_absent "f2: no half-populated moon64 directory" "$sb/home/.local/share/moon64"
assert_contains "f2: says it removed the SLSsteam directory too" "removed $sb/home/.local/share/SLSsteam, which this run had created" "$out"
assert_absent "f2: no empty SLSsteam directory left behind" "$sb/home/.local/share/SLSsteam"

# Same failure over an earlier install: put back exactly as it was.
sb="$(make_sandbox f3 clean)"
MD="$sb/home/.local/share/moon64"
mkdir -p "$MD/src/keep" "$MD/staged"
printf 'old\n' > "$MD/SLSsteam.so.64"
printf 'old\n' > "$MD/moon64"
printf 'old\n' > "$MD/.hidden"
printf 'checkout\n' > "$MD/src/keep/file"
before="$(snapshot "$MD")"
printf 'not the pinned release\n' > "$sb/wrong.7z"
out="$(GETSH_SLS32_URL="file://$sb/wrong.7z" pipe_get "$sb" 2>&1)"; rc=$?
assert_rc "f3: fails" 1 "$rc" "$out"
assert_contains "f3: after staging" "staged $MD/SLSsteam.so.64" "$out"
assert_contains "f3: says it restored" "restored $MD to what it was before this run" "$out"
assert_eq "f3: the earlier install is byte-identical" "$before" "$(snapshot "$MD")"
assert_eq "f3: temporary files removed" "" "$(ls -A "$sb/tmp")"
assert_absent "f3: the SLSsteam directory this run created is gone" "$sb/home/.local/share/SLSsteam"

# A failure on a machine that already had ~/.local/share/SLSsteam leaves it be.
sb="$(make_sandbox f4)"
before="$(snapshot "$sb/home/.local/share/SLSsteam")"
GETSH_ENV=(SLSM_PREBUILT_URL="file://$REL_BAD/SLSsteam.so")
out="$(pipe_get "$sb" 2>&1)"; rc=$?
GETSH_ENV=()
assert_rc "f4: fails" 1 "$rc" "$out"
assert_eq "f4: the existing SLSsteam directory is untouched" "$before" "$(snapshot "$sb/home/.local/share/SLSsteam")"

# --- (h) through the pipe, a release without netsock64.so and without a binding
# line (what v1.0.0 publishes): built from the fetched source with gcc, a loud
# but successful degraded install without it ---------------------------------
REL_URL="https://github.com/KadirBerkpolat1/slsteam-moon-64/releases/latest/download"
sb="$(make_sandbox h1)"
MD="$sb/home/.local/share/moon64"
out="$(GETSH_RELEASE="$REL_ABSENT" GETSH_PATH="$PATH" pipe_get "$sb" 2>&1)"; rc=$?
assert_rc "h1: with gcc the install succeeds" 0 "$rc" "$out"
assert_contains "h1: fetched the cert patch source" "https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/patches/netsock64/steamclient_audit64.c" "$(raw_urls "$sb")"
assert_contains "h1: says the release has none" "the release has no $REL_URL/netsock64.so and its pattern-status.txt names none" "$out"
assert_contains "h1: builds it from the fetched source" "/patches/netsock64/steamclient_audit64.c" "$(grep -F 'netsock64.so: built from ' <<< "$out")"
assert_contains "h1: from get.sh's temporary copy" "netsock64.so: built from $sb/tmp/moon64-get." "$out"
assert_eq "h1: a 64-bit shared object" "ELF 64-bit LSB shared object, x86-64" "$(file -b "$MD/netsock64.so" 2>/dev/null | cut -d, -f1-2)"
assert_contains "h1: recorded as built" "source=built" "$(cat "$MD/netsock64.state" 2>/dev/null)"
assert_not_contains "h1: no degraded warning" "the P2P cert patch will be inactive" "$out"
assert_contains "h1: close: cert patch active, built from source" "P2P cert patch: active once you run moon64 on (netsock64.so built from source)" "$out"
assert_same "h1: SLSsteam.so.64 is the release's" "$REL_ABSENT/SLSsteam.so" "$MD/SLSsteam.so.64"

sb="$(make_sandbox h2)"
MD="$sb/home/.local/share/moon64"
out="$(GETSH_RELEASE="$REL_ABSENT" pipe_get "$sb" 2>&1)"; rc=$?
assert_rc "h2: without gcc the install still succeeds" 0 "$rc" "$out"
assert_contains "h2: warns loudly" "the release has no netsock64.so and gcc is not installed to build it: the P2P cert patch will be inactive" "$out"
assert_contains "h2: degraded, not failed" "this is a degraded feature, not a failed install" "$out"
assert_contains "h2: summary" "netsock64.so: none (the P2P cert patch is inactive)" "$out"
assert_contains "h2: get.sh reports success" "nothing is active yet" "$out"
assert_contains "h2: close: cert patch inactive, and what gcc or a release would give" $'nothing is active yet.\nP2P cert patch: INACTIVE - co-op joins that need peer-to-peer (Satisfactory, REPO) will fail.\n                install gcc and run this again to build it, or wait for a release that ships netsock64.so.\n' "$out"
assert_not_contains "h2: close: never claims the patch is active" "P2P cert patch: active" "$out"
assert_absent "h2: no netsock64.so" "$MD/netsock64.so"
assert_same "h2: SLSsteam.so.64 is the release's" "$REL_ABSENT/SLSsteam.so" "$MD/SLSsteam.so.64"

# --- (i) through the pipe, a release whose pattern-status.txt names a
# netsock64.so that is not there: a hard refusal, nothing staged ---------------
sb="$(make_sandbox i1 clean)"
out="$(GETSH_RELEASE="$REL_BOUND_MISSING" GETSH_PATH="$PATH" pipe_get "$sb" 2>&1)"; rc=$?
assert_rc "i1: refused even with gcc present" 1 "$rc" "$out"
assert_contains "i1: says why" "$REL_URL/pattern-status.txt names a netsock64.so (netsock64_sha256=), but $REL_URL/netsock64.so cannot be downloaded" "$out"
assert_contains "i1: refuses" "refusing to stage an unverified prebuilt netsock64.so; nothing was staged" "$out"
assert_not_contains "i1: does not claim the release lacks it" "the release has no" "$out"
assert_not_contains "i1: does not build a substitute" "netsock64.so: built from" "$out"
assert_absent "i1: no moon64 directory" "$sb/home/.local/share/moon64"
assert_absent "i1: no SLSsteam directory" "$sb/home/.local/share/SLSsteam"
assert_eq "i1: temporary files removed" "" "$(ls -A "$sb/tmp")"

# --- (g) missing prerequisites: listed, with the re-run command; no sudo ------
sb="$(make_sandbox g)"
out="$(GETSH_PATH="$NOCC_NO_READELF" pipe_get "$sb" 2>&1)"; rc=$?
assert_rc "g1: fails" 1 "$rc" "$out"
assert_contains "g1: names what is missing" "missing prerequisites: readelf" "$out"
assert_contains "g1: the package command" "sudo pacman -S --needed binutils" "$out"
assert_contains "g1: the re-run with --install-deps" "curl -fsSL https://raw.githubusercontent.com/KadirBerkpolat1/moon64/main/get.sh | bash -s -- --install-deps" "$out"
assert_absent "g1: sudo never ran" "$sb/sudo.log"
assert_absent "g1: nothing left behind" "$sb/home/.local/share/moon64"

out="$(GETSH_PATH="$NOCC_NO_READELF" pipe_get "$sb" --install-deps 2>&1)"; rc=$?
assert_rc "g2: --install-deps reaches install.sh and stops at a password sudo" 1 "$rc" "$out"
assert_contains "g2: passed through" "moon64: running install.sh --prebuilt --install-deps" "$out"
assert_contains "g2: install.sh will not prompt" "sudo needs a password, and install.sh will not prompt for one" "$out"
assert_eq "g2: sudo was only asked non-interactively" "-n true" "$(cat "$sb/sudo.log" 2>/dev/null)"
assert_not_contains "g2: no second re-run hint" "| bash -s -- --install-deps" "$out"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
