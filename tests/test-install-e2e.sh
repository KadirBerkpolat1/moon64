#!/usr/bin/env bash
# End-to-end sandbox test: a clean machine with only native Steam installed,
# missing one prerequisite, runs `./install.sh --prebuilt --install-deps`, then
# `moon64 doctor`, `moon64 on`, launches Steam through its desktop entry, and
# `moon64 off`. Everything runs in a throwaway HOME against a fake Steam root,
# with the prebuilt release and the 32-bit rollback release served over file://.
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

if ! command -v 7z >/dev/null 2>&1 && ! command -v bsdtar >/dev/null 2>&1; then
    printf 'FAIL [setup]: need 7z or bsdtar to build the rollback release fixture\n' >&2
    exit 1
fi

sb="$TMP_ROOT/sb"
h="$sb/home"
STEAM="$h/.local/share/Steam"
SLS="$h/.local/share/SLSsteam"
APPS="$h/.local/share/applications"
SYS_APPS="$sb/usr-share/applications"
mkdir -p "$h/.steam" "$STEAM/steamrt64" "$SYS_APPS" "$sb/moon64" "$sb/tmp" "$sb/proc" \
    "$sb/src/res" "$sb/stub-bin" "$sb/rel" "$sb/rel32"

# --- fixtures ------------------------------------------------------------
# Native Steam, already started once: steamrt64 is populated. steam.sh records
# what a desktop-entry launch hands it instead of starting a client.
printf '#!/usr/bin/env bash\nexit 0\n' > "$STEAM/steamrt64/steam"
chmod +x "$STEAM/steamrt64/steam"
printf 'void steamclient_stub(void) {}\n' | gcc -shared -fPIC -x c - -o "$STEAM/steamrt64/steamclient.so"
LAUNCH_LOG="$sb/launch.log"
cat > "$STEAM/steam.sh" <<SH
#!/usr/bin/env bash
{
    printf 'ARGS=%s\n' "\$*"
    printf 'STEAM_FORCE_CLIENT=%s\n' "\${STEAM_FORCE_CLIENT-<UNSET>}"
    printf 'LD_AUDIT=%s\n' "\${LD_AUDIT-<UNSET>}"
} > '$LAUNCH_LOG'
SH
chmod +x "$STEAM/steam.sh"

# The distribution's Steam desktop entry, as the steam package installs it.
cat > "$SYS_APPS/steam.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Steam
Comment=Application for managing and playing games on Steam
Exec=/usr/bin/steam %U
Icon=steam
Terminal=false
Type=Application
Categories=Network;FileTransfer;Game;
MimeType=x-scheme-handler/steam;x-scheme-handler/steamlink;
Actions=Store;Library;
PrefersNonDefaultGPU=true

[Desktop Action Store]
Name=Store
Exec=steam steam://store

[Desktop Action Library]
Name=Library
Exec=steam steam://open/games
DESKTOP
SYS_ENTRY_SHA="$(sha "$SYS_APPS/steam.desktop")"

# The project's prebuilt release: library, .sha256, and a pattern-status.txt
# bound to the library.
printf 'void slsteam_prebuilt(void) {}\n' | gcc -shared -fPIC -x c - -o "$sb/rel/SLSsteam.so"
printf '%s  SLSsteam.so\n' "$(sha "$sb/rel/SLSsteam.so")" > "$sb/rel/SLSsteam.so.sha256"
printf 'arch=x86_64\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=ready\nbinary_sha256=%s\n' \
    "$(sha "$sb/rel/SLSsteam.so")" > "$sb/rel/pattern-status.txt"

# Upstream's 32-bit release, the rollback target on a machine without it.
mkdir -p "$sb/rel32/tree/bin"
{ printf '\177ELF\001\001\001'; head -c 9 /dev/zero; printf '\003\000\003\000\001\000\000\000'; head -c 28 /dev/zero; } \
    > "$sb/rel32/tree/bin/SLSsteam.so"
if command -v 7z >/dev/null 2>&1; then
    (cd "$sb/rel32/tree" && 7z a -t7z "$sb/rel32/SLSsteam-Any-release.7z" bin >/dev/null)
else
    (cd "$sb/rel32/tree" && bsdtar --format 7zip -cf "$sb/rel32/SLSsteam-Any-release.7z" bin)
fi

# A source tree whose build must never run: --prebuilt has a release to use.
printf 'all:\n\t@: > %s/make-ran; exit 99\n' "$sb" > "$sb/src/Makefile"

# systemd is never asked to do anything for real.
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/stub-bin/systemctl"
chmod +x "$sb/stub-bin/systemctl"

# The stranger's machine has no readelf. Directories that hold it are mirrored
# without it; the stub pacman "installs" binutils by linking the real one in.
REAL_READELF="$(command -v readelf)"
machine_path=""
n=0
IFS=: read -ra path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
    [ -d "$d" ] || continue
    if [ -e "$d/readelf" ]; then
        n=$((n + 1))
        m="$TMP_ROOT/no-readelf-$n"
        mkdir -p "$m"
        for f in "$d"/*; do
            [ "${f##*/}" = readelf ] && continue
            [ -x "$f" ] && ln -s "$f" "$m/${f##*/}"
        done
        d="$m"
    fi
    machine_path="${machine_path:+$machine_path:}$d"
done
cat > "$sb/stub-bin/sudo" <<'SH'
#!/usr/bin/env bash
[ "$1" = -n ] || exit 99
shift
[ "$1" = true ] && exit 0
exec "$@"
SH
cat > "$sb/stub-bin/pacman" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$sb/pacman.log'
ln -s '$REAL_READELF' '$sb/stub-bin/readelf'
SH
chmod +x "$sb/stub-bin/sudo" "$sb/stub-bin/pacman"

run() {
    env -u MOON64_APPS_DIR -u MOON64_ENV_CONF -u MOON64_ENV_D_DIR -u SLSM_PREBUILT_URL \
        -u LD_AUDIT -u LD_PRELOAD -u STEAM_FORCE_CLIENT \
        PATH="$sb/stub-bin:$machine_path" HOME="$h" MOON64_DIR="$sb/moon64" SLS64_SRC="$sb/src" \
        XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" XDG_DATA_DIRS="${SYS_APPS%/applications}" \
        SLSM_PROC_ROOT="$sb/proc" TMPDIR="$sb/tmp" LUMEN_FIX_INSTALLS_DIR="$sb/none" \
        SLSM_PKG_MANAGER=pacman \
        SLSM_PREBUILT_URL="file://$sb/rel/SLSsteam.so" \
        SLSM_SLS32_URL="file://$sb/rel32/SLSsteam-Any-release.7z" \
        SLSM_SLS32_SHA256="$(sha "$sb/rel32/SLSsteam-Any-release.7z")" \
        SLSM_SLS32_VERSION=20990101000000 \
        "$@"
}

# snapshot <dir> — every file and symlink under <dir> with its content hash.
snapshot() {
    local root="$1" p
    ( cd "$root" && find . \( -type f -o -type l \) -print | LC_ALL=C sort ) | while IFS= read -r p; do
        if [ -L "$root/$p" ]; then
            printf 'L %s -> %s\n' "$p" "$(readlink "$root/$p")"
        else
            printf 'F %s %s\n' "$p" "$(sha "$root/$p")"
        fi
    done
}

# exec_line <desktop file> [action] — the Exec= of the main group or an action.
exec_line() {
    awk -v grp="${2:+Desktop Action $2}" '
        /^\[/ { cur = substr($0, 2, length($0) - 2); next }
        cur == (grp == "" ? "Desktop Entry" : grp) && /^Exec=/ { print substr($0, 6); exit }
    ' "$1"
}

HOME_BEFORE="$(snapshot "$h")"

# --- 1. install.sh -------------------------------------------------------
out="$(run bash "$REPO_ROOT/install.sh" --prebuilt --install-deps 2>&1)"; rc=$?
assert_rc "1: install.sh --prebuilt --install-deps succeeds" 0 "$rc" "$out"
assert_contains "1: detects the missing prerequisite" "missing prerequisites: readelf" "$out"
assert_contains "1: installs it non-interactively" "running: sudo -n pacman -S --needed --noconfirm binutils" "$out"
assert_eq "1: package manager ran once, for binutils only" "-S --needed --noconfirm binutils" "$(cat "$sb/pacman.log" 2>/dev/null)"
assert_contains "1: prebuilt sha256 verified" "prebuilt sha256 matches file://$sb/rel/SLSsteam.so.sha256" "$out"
assert_contains "1: status file bound to the prebuilt" "pattern-status.txt was measured on this SLSsteam.so" "$out"
assert_contains "1: pattern gate passed" "x86_64 pattern table complete" "$out"
assert_same "1: prebuilt staged byte-exact" "$sb/rel/SLSsteam.so" "$sb/moon64/SLSsteam.so.64"
assert_absent "1: nothing was built" "$sb/make-ran"
assert_contains "1: rollback target fetched" "rollback target: upstream SLSsteam 20990101000000 (32-bit) saved as" "$out"
assert_same "1: rollback target is the upstream 32-bit library" "$sb/rel32/tree/bin/SLSsteam.so" "$SLS/SLSsteam.so.32"
assert_contains "1: summary says prebuilt" "SLSsteam.so.64: prebuilt (file://$sb/rel/SLSsteam.so)" "$out"
assert_contains "1: activates nothing" "staging complete; nothing has been activated" "$out"
assert_absent "1: no desktop override yet" "$APPS/steam.desktop"
assert_eq "1: system desktop entry untouched" "$SYS_ENTRY_SHA" "$(sha "$SYS_APPS/steam.desktop")"
HOME_INSTALLED="$(snapshot "$h")"

# --- 2. doctor before activation -----------------------------------------
out="$(run bash "$sb/moon64/moon64" doctor 2>&1)"; rc=$?
assert_rc "2: doctor finds no blocking problem" 0 "$rc" "$out"
assert_contains "2: staged 64-bit is ready" "SLSsteam.so 64-bit staged" "$out"
assert_contains "2: names the prebuilt" "staged SLSsteam.so.64: prebuilt, downloaded from file://$sb/rel/SLSsteam.so" "$out"
assert_contains "2: rollback target reported" "$SLS/SLSsteam.so.32: upstream SLSsteam 20990101000000, fetched by install.sh" "$out"
assert_contains "2: says what on will do to the entry" "$SYS_APPS/steam.desktop runs /usr/bin/steam; 'moon64 on' points it at $SLS/path/steam" "$out"

# --- 3. on ---------------------------------------------------------------
out="$(run bash "$sb/moon64/moon64" on 2>&1)"; rc=$?
assert_rc "3: on succeeds" 0 "$rc" "$out"
assert_same "3: active SLSsteam.so is the prebuilt" "$sb/rel/SLSsteam.so" "$SLS/SLSsteam.so"
assert_same "3: path/steam is the 64-bit wrapper" "$sb/moon64/wrapper.64.sh" "$SLS/path/steam"
assert_eq "3: desktop entry starts the wrapper" "$SLS/path/steam %U" "$(exec_line "$APPS/steam.desktop")"
assert_eq "3: Store action starts the wrapper" "$SLS/path/steam steam://store" "$(exec_line "$APPS/steam.desktop" Store)"
assert_eq "3: Library action starts the wrapper" "$SLS/path/steam steam://open/games" "$(exec_line "$APPS/steam.desktop" Library)"
assert_eq "3: system entry still untouched" "$SYS_ENTRY_SHA" "$(sha "$SYS_APPS/steam.desktop")"

out="$(run bash "$sb/moon64/moon64" doctor 2>&1)"; rc=$?
assert_rc "3: doctor after on finds no blocking problem" 0 "$rc" "$out"
assert_contains "3: doctor: active binary is the prebuilt" "active SLSsteam.so is the staged binary (prebuilt, downloaded from file://$sb/rel/SLSsteam.so)" "$out"
assert_contains "3: doctor: entry starts the wrapper" "$APPS/steam.desktop starts the wrapper ($SLS/path/steam)" "$out"

# --- 4. launching Steam from the desktop entry ----------------------------
read -ra launch <<< "$(exec_line "$APPS/steam.desktop")"
launch=("${launch[@]/\%U/steam://open/main}")
run "${launch[@]}" >/dev/null 2>&1; rc=$?
assert_rc "4: the desktop entry's command starts Steam" 0 "$rc"
launched="$(cat "$LAUNCH_LOG" 2>/dev/null)"
assert_contains "4: Steam got the URL" "ARGS=steam://open/main" "$launched"
assert_contains "4: Steam runs the 64-bit client" "STEAM_FORCE_CLIENT=steamrt64" "$launched"
assert_contains "4: SLSsteam is loaded" "$SLS/SLSsteam.so" "$(sed -n 's/^LD_AUDIT=//p' "$LAUNCH_LOG" 2>/dev/null)"

# --- 5. off ---------------------------------------------------------------
out="$(run bash "$sb/moon64/moon64" off 2>&1)"; rc=$?
assert_rc "5: off succeeds" 0 "$rc" "$out"
assert_same "5: active SLSsteam.so is the 32-bit rollback target" "$SLS/SLSsteam.so.32" "$SLS/SLSsteam.so"
assert_absent "5: user-level override removed" "$APPS/steam.desktop"
assert_eq "5: system entry still untouched" "$SYS_ENTRY_SHA" "$(sha "$SYS_APPS/steam.desktop")"
HOME_OFF="$(snapshot "$h")"
assert_absent "5: the wrapper on installed is gone" "$SLS/path/steam"
assert_absent "5: and so is its directory" "$SLS/path"
assert_absent "5: Steam is not forced onto the 32-bit client" "$STEAM/.steam-disable-steamrt64-client"
assert_absent "5: nor onto the 64-bit one" "$STEAM/.steam-enable-steamrt64-client"
assert_contains "5: says Steam is back to how it was" "moon64 is off — Steam starts as it did before 'moon64 on', without SLSsteam" "$out"

# The whole home, before and after: install.sh only added the rollback target,
# and on+off only left that target in place as SLSsteam.so (inert: nothing
# loads it without an SLSsteam launcher).
assert_eq "5: install.sh added only the rollback target to HOME" \
    "> F ./.local/share/SLSsteam/SLSsteam.so.32 $(sha "$sb/rel32/tree/bin/SLSsteam.so")" \
    "$(diff <(printf '%s\n' "$HOME_BEFORE") <(printf '%s\n' "$HOME_INSTALLED") | sed -n '/^[<>]/p')"
assert_eq "5: on+off left HOME as install.sh did, plus the inert SLSsteam.so" \
    "> F ./.local/share/SLSsteam/SLSsteam.so $(sha "$sb/rel32/tree/bin/SLSsteam.so")" \
    "$(diff <(printf '%s\n' "$HOME_INSTALLED") <(printf '%s\n' "$HOME_OFF") | sed -n '/^[<>]/p')"

out="$(run bash "$sb/moon64/moon64" doctor 2>&1)"; rc=$?
assert_rc "5: doctor after off finds no blocking problem" 0 "$rc" "$out"
assert_contains "5: doctor offers on again" "'moon64 on' points it at $SLS/path/steam" "$out"

# --- 6. a second on/off cycle lands in the same places --------------------
out="$(run bash "$sb/moon64/moon64" on 2>&1)"; rc=$?
assert_rc "6: on again succeeds" 0 "$rc" "$out"
assert_eq "6: entry starts the wrapper again" "$SLS/path/steam %U" "$(exec_line "$APPS/steam.desktop")"
assert_same "6: the prebuilt is active again" "$sb/rel/SLSsteam.so" "$SLS/SLSsteam.so"
out="$(run bash "$sb/moon64/moon64" off 2>&1)"; rc=$?
assert_rc "6: off again succeeds" 0 "$rc" "$out"
assert_eq "6: HOME is byte-identical to after the first off" "$HOME_OFF" "$(snapshot "$h")"
assert_eq "6: system entry never touched" "$SYS_ENTRY_SHA" "$(sha "$SYS_APPS/steam.desktop")"

# --- 7. a launcher installed after 'on' is not moon64's to remove -----------
out="$(run bash "$sb/moon64/moon64" on 2>&1)"; rc=$?
assert_rc "7: on succeeds" 0 "$rc" "$out"
printf '#!/usr/bin/env bash\n# upstream SLSsteam launcher, installed after on\n' > "$SLS/path/steam"
cp "$SLS/path/steam" "$sb/foreign-launcher"
out="$(run bash "$sb/moon64/moon64" off 2>&1)"; rc=$?
assert_rc "7: off succeeds" 0 "$rc" "$out"
assert_same "7: the other launcher is left as is" "$sb/foreign-launcher" "$SLS/path/steam"
assert_contains "7: and off says so" "$SLS/path/steam was replaced after 'moon64 on'; left as is" "$out"
assert_contains "7: falls back to the 32-bit stack's client switch" "32-bit stack active" "$out"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
