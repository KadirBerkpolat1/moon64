#!/usr/bin/env bash
# Sandbox test for the Steam desktop entry handling of `moon64 on|off|doctor`.
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

assert_contains() {
    local label="$1" substr="$2" text="$3"
    case "$text" in
        *"$substr"*) pass "$label" ;;
        *) fail "$label" "missing $(printf '%q' "$substr") in:"$'\n'"$text" ;;
    esac
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then pass "$label"; else fail "$label" "expected $(printf '%q' "$expected"), got $(printf '%q' "$actual")"; fi
}

assert_same() {
    local label="$1" a="$2" b="$3"
    if cmp -s "$a" "$b"; then pass "$label"; else fail "$label" "$a differs from $b"; fi
}

assert_exists() {
    if [ -e "$2" ]; then pass "$1"; else fail "$1" "missing: $2"; fi
}

assert_absent() {
    if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "unexpected file: $2"; fi
}

# The Exec= lines of a file, one per line.
exec_lines() { sed -n 's/^Exec=//p' "$1"; }
# Everything except Exec= lines, byte-for-byte (CR and missing final newline kept).
non_exec() { awk 'BEGIN { RS = "\n"; ORS = "\n" } !/^Exec=/' "$1"; }

make_elf() {
    local bits="$1" out="$2"
    if [ "$bits" = 32 ]; then
        { printf '\177ELF\001\001\001'; head -c 9 /dev/zero; printf '\003\000\003\000\001\000\000\000'; head -c 28 /dev/zero; } > "$out"
    else
        { printf '\177ELF\002\001\001'; head -c 9 /dev/zero; printf '\003\000\076\000\001\000\000\000'; head -c 40 /dev/zero; } > "$out"
    fi
}

# systemctl stub: `on`/`off` must never reach the real user manager.
STUB_BIN="$TMP_ROOT/stub-bin"
mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/systemctl"
chmod +x "$STUB_BIN/systemctl"

# make_sandbox <name> [home-dir-name] — staged 64-bit stack, 32-bit rollback
# target, empty /proc, and a system data dir. Prints the sandbox root.
make_sandbox() {
    local sb="$TMP_ROOT/$1" home_name="${2:-home}"
    local h="$sb/$home_name"
    mkdir -p "$h/.steam" "$h/.local/share/Steam/steamrt64" "$h/.local/share/SLSsteam" \
             "$h/.config" "$sb/moon64" "$sb/proc" "$sb/usr/share/applications"
    make_elf 64 "$sb/moon64/SLSsteam.so.64"
    make_elf 32 "$h/.local/share/SLSsteam/SLSsteam.so.32"
    cp "$h/.local/share/SLSsteam/SLSsteam.so.32" "$h/.local/share/SLSsteam/SLSsteam.so"
    printf '#!/usr/bin/env bash\n# 64-bit wrapper stand-in\n' > "$sb/moon64/wrapper.64.sh"
    printf '%s' "$sb"
}

# run_moon <sandbox> <home> <cmd> — moon64 confined to the sandbox.
run_moon() {
    local sb="$1" h="$2"; shift 2
    env -u MOON64_APPS_DIR -u MOON64_ENV_CONF -u MOON64_ENV_D_DIR \
        PATH="$STUB_BIN:$PATH" HOME="$h" MOON64_DIR="$sb/moon64" \
        XDG_CONFIG_HOME="$h/.config" XDG_DATA_HOME="$h/.local/share" \
        XDG_DATA_DIRS="$sb/usr/share" SLSM_PROC_ROOT="$sb/proc" \
        LUMEN_FIX_INSTALLS_DIR="$sb/none" \
        bash "$REPO_ROOT/bin/moon64" "$@" 2>&1
}

# A distro-style entry: main Exec, TryExec, localized keys, two actions.
write_system_entry() {
    cat > "$1" <<'DESKTOP'
[Desktop Entry]
Name=Steam
Comment=Application for managing and playing games on Steam
Comment[tr]=Steam üzerinden oyun oynama ve düzenleme uygulaması
Exec=/usr/bin/steam %U
TryExec=steam
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
Exec=/usr/bin/steam steam://open/games
DESKTOP
}

# --- (a) clean machine: only the system entry exists ----------------------
sb="$(make_sandbox a-clean)"; h="$sb/home"
sys="$sb/usr/share/applications/steam.desktop"
user="$h/.local/share/applications/steam.desktop"
wrap="$h/.local/share/SLSsteam/path/steam"
write_system_entry "$sys"
cp -a "$sys" "$sb/system.pristine"

out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_rc "a1: on succeeds on a clean machine" 0 "$rc" "$out"
assert_contains "a1: on reports the desktop entry" "desktop entry: $user starts $wrap" "$out"
assert_contains "a1: on points the launcher at the stack" "start Steam from your normal launcher" "$out"
assert_exists "a1: user-level override created" "$user"
assert_exists "a1: override marker recorded" "$user.moon64-created"
assert_absent "a1: no backup for a created override" "$user.moon64-bak"
assert_same "a1: system entry untouched" "$sys" "$sb/system.pristine"
assert_eq "a1: every Exec= runs the wrapper" \
    "$wrap %U"$'\n'"$wrap steam://store"$'\n'"$wrap steam://open/games" "$(exec_lines "$user")"
assert_eq "a1: all other lines byte-identical" "$(non_exec "$sys" | od -c)" "$(non_exec "$user" | od -c)"

cp -a "$user" "$sb/after-first-on"
out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_rc "a2: second on succeeds" 0 "$rc" "$out"
assert_same "a2: second on leaves the entry byte-identical" "$user" "$sb/after-first-on"
assert_eq "a2: no duplicated Exec= keys" 3 "$(exec_lines "$user" | wc -l | tr -d ' ')"
assert_absent "a2: still no backup" "$user.moon64-bak"

out="$(run_moon "$sb" "$h" doctor)"
assert_contains "a3: doctor reports the wrapper entry" "$user starts the wrapper ($wrap)" "$out"
assert_contains "a3: doctor names the created override" "user-level override created by moon64" "$out"

out="$(run_moon "$sb" "$h" off)"; rc=$?
assert_rc "a4: off succeeds" 0 "$rc" "$out"
assert_contains "a4: off reports removing the override" "removed the moon64 override $user" "$out"
assert_absent "a4: override removed" "$user"
assert_absent "a4: marker removed" "$user.moon64-created"
assert_same "a4: system entry still untouched" "$sys" "$sb/system.pristine"

out="$(run_moon "$sb" "$h" doctor)"
assert_contains "a5: doctor after off explains what on will do" "$sys runs /usr/bin/steam; 'moon64 on' points it at $wrap" "$out"

# --- (b) existing user-level entry from upstream SLSsteam's setup.sh -------
sb="$(make_sandbox b-user)"; h="$sb/home"
user="$h/.local/share/applications/steam.desktop"
wrap="$h/.local/share/SLSsteam/path/steam"
mkdir -p "$h/.local/share/applications"
{
    printf '[Desktop Entry]\r\n'
    printf 'Name=Steam\r\n'
    printf 'Exec=env LD_AUDIT="%s/library-inject.so:%s/SLSsteam.so" /usr/bin/steam %%U\r\n' \
        "$h/.local/share/SLSsteam" "$h/.local/share/SLSsteam"
    printf 'Icon=steam\r\n'
    printf '\r\n[Desktop Action Library]\r\n'
    printf 'Name=Library\r\n'
    printf 'Exec=steam steam://open/games'
} > "$user"
chmod 755 "$user"
cp -a "$user" "$sb/user.pristine"

out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_rc "b1: on succeeds with an upstream user entry" 0 "$rc" "$out"
assert_same "b1: original saved as .moon64-bak" "$user.moon64-bak" "$sb/user.pristine"
assert_absent "b1: no override marker for an edited file" "$user.moon64-created"
assert_eq "b1: own LD_AUDIT dropped, CRLF kept" \
    "$wrap %U"$'\r\n'"$wrap steam://open/games" "$(exec_lines "$user")"
assert_eq "b1: non-Exec bytes identical" "$(non_exec "$sb/user.pristine" | od -c)" "$(non_exec "$user" | od -c)"
assert_eq "b1: missing final newline preserved" "s" "$(tail -c1 "$user")"
assert_eq "b1: file mode preserved" 755 "$(stat -c %a "$user")"

cp -a "$user" "$sb/after-first-on"
out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_rc "b2: second on succeeds" 0 "$rc" "$out"
assert_same "b2: entry unchanged on re-run" "$user" "$sb/after-first-on"
assert_same "b2: backup never overwritten" "$user.moon64-bak" "$sb/user.pristine"

out="$(run_moon "$sb" "$h" off)"; rc=$?
assert_rc "b3: off succeeds" 0 "$rc" "$out"
assert_contains "b3: off reports the restore" "desktop entry: $user restored (byte-exact)" "$out"
assert_same "b3: entry restored byte-for-byte" "$user" "$sb/user.pristine"
assert_absent "b3: backup consumed" "$user.moon64-bak"

# --- (c) a pre-existing backup is never replaced --------------------------
sb="$(make_sandbox c-oldbak)"; h="$sb/home"
user="$h/.local/share/applications/steam.desktop"
mkdir -p "$h/.local/share/applications"
printf '[Desktop Entry]\nExec=/usr/bin/steam %%U\n' > "$user"
printf '[Desktop Entry]\nExec=/usr/bin/steam -oldbackup %%U\n' > "$user.moon64-bak"
cp -a "$user.moon64-bak" "$sb/bak.pristine"
out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_rc "c1: on succeeds" 0 "$rc" "$out"
assert_same "c1: existing backup kept" "$user.moon64-bak" "$sb/bak.pristine"

# --- (d) foreign LD_AUDIT and other env assignments survive ---------------
sb="$(make_sandbox d-foreign-env)"; h="$sb/home"
user="$h/.local/share/applications/steam.desktop"
wrap="$h/.local/share/SLSsteam/path/steam"
mkdir -p "$h/.local/share/applications"
printf '[Desktop Entry]\nExec=env LD_AUDIT=/opt/foreign.so STEAM_FRAME_FORCE_CLOSE=1 /usr/bin/steam -silent %%U\n' > "$user"
out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_rc "d1: on succeeds" 0 "$rc" "$out"
assert_eq "d1: foreign env kept, program swapped" \
    "env LD_AUDIT=/opt/foreign.so STEAM_FRAME_FORCE_CLOSE=1 $wrap -silent %U" "$(exec_lines "$user")"

# --- (e) unrecognised Exec= is refused before anything is switched --------
sb="$(make_sandbox e-refuse)"; h="$sb/home"
user="$h/.local/share/applications/steam.desktop"
mkdir -p "$h/.local/share/applications"
printf '[Desktop Entry]\nExec=flatpak run com.valvesoftware.Steam %%U\n' > "$user"
cp -a "$user" "$sb/user.pristine"
cp -a "$h/.local/share/SLSsteam/SLSsteam.so" "$sb/sls.pristine"
out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_rc "e1: on refuses an unrecognised Exec=" 1 "$rc" "$out"
assert_contains "e1: says it refuses to guess" "refusing to guess" "$out"
assert_same "e1: entry untouched" "$user" "$sb/user.pristine"
assert_absent "e1: no backup taken" "$user.moon64-bak"
assert_same "e1: SLSsteam.so not switched" "$h/.local/share/SLSsteam/SLSsteam.so" "$sb/sls.pristine"
assert_absent "e1: environment.d not written" "$h/.config/environment.d/steam-32bit.conf"
out="$(run_moon "$sb" "$h" doctor)"
assert_contains "e2: doctor flags the entry in advance" "'moon64 on' will refuse to rewrite it" "$out"

# --- (f) entry already starting the wrapper: left alone both ways ---------
sb="$(make_sandbox f-ours)"; h="$sb/home"
user="$h/.local/share/applications/steam.desktop"
wrap="$h/.local/share/SLSsteam/path/steam"
mkdir -p "$h/.local/share/applications"
printf '[Desktop Entry]\nExec=%s %%U\n\n[Desktop Action Store]\nExec=%s steam://store\n' "$wrap" "$wrap" > "$user"
cp -a "$user" "$sb/user.pristine"
out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_rc "f1: on succeeds" 0 "$rc" "$out"
assert_same "f1: entry unchanged" "$user" "$sb/user.pristine"
assert_absent "f1: no backup" "$user.moon64-bak"
assert_absent "f1: no marker" "$user.moon64-created"
out="$(run_moon "$sb" "$h" off)"; rc=$?
assert_rc "f2: off succeeds" 0 "$rc" "$out"
assert_same "f2: entry still unchanged" "$user" "$sb/user.pristine"

# --- (g) doctor: entry bypassing an active 64-bit stack is a problem -------
sb="$(make_sandbox g-doctor)"; h="$sb/home"
write_system_entry "$sb/usr/share/applications/steam.desktop"
make_elf 64 "$h/.local/share/SLSsteam/SLSsteam.so"
out="$(run_moon "$sb" "$h" doctor)"; rc=$?
assert_contains "g1: doctor flags the bypass" "a normal Steam launch skips the 64-bit stack" "$out"
if [ "$rc" -ne 0 ]; then pass "g1: doctor counts it as blocking (rc=$rc)"; else fail "g1: doctor rc" "expected non-zero"; fi

# --- (h) HOME with a space: the wrapper path is quoted ---------------------
sb="$(make_sandbox h-space 'my home')"; h="$sb/my home"
user="$h/.local/share/applications/steam.desktop"
wrap="$h/.local/share/SLSsteam/path/steam"
write_system_entry "$sb/usr/share/applications/steam.desktop"
out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_rc "h1: on succeeds" 0 "$rc" "$out"
assert_eq "h1: main Exec quotes the path" "\"$wrap\" %U" "$(exec_lines "$user" | head -n1)"
cp -a "$user" "$sb/after-first-on"
out="$(run_moon "$sb" "$h" on)"; rc=$?
assert_same "h2: quoted entry recognised as ours on re-run" "$user" "$sb/after-first-on"
out="$(run_moon "$sb" "$h" off)"; rc=$?
assert_rc "h3: off succeeds" 0 "$rc" "$out"
assert_absent "h3: override removed" "$user"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
