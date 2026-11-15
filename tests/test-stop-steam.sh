#!/usr/bin/env bash
# Sandbox test for `moon64 stop-steam` and install.sh auto-stop wiring.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
PIDS_TO_KILL=()
cleanup() {
    local p
    for p in "${PIDS_TO_KILL[@]:-}"; do
        [ -n "$p" ] && kill -KILL "$p" 2>/dev/null || true
        [ -n "$p" ] && wait "$p" 2>/dev/null || true
    done
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

PASS=0
FAIL=0

assert_rc() {
    local label="$1" expected="$2" actual="$3" out="${4:-}"
    if [ "$expected" -eq "$actual" ]; then
        printf 'PASS [%s] (rc=%s)\n' "$label" "$actual"
        PASS=$((PASS + 1))
    else
        printf 'FAIL [%s]: expected rc=%s, got rc=%s\n%s\n' "$label" "$expected" "$actual" "$out" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" substr="$2" text="$3"
    case "$text" in
        *"$substr"*)
            printf 'PASS [%s]\n' "$label"
            PASS=$((PASS + 1))
            ;;
        *)
            printf 'FAIL [%s]: missing %q in:\n%s\n' "$label" "$substr" "$text" >&2
            FAIL=$((FAIL + 1))
            ;;
    esac
}

assert_not_exists() {
    local label="$1" path="$2"
    if [ ! -e "$path" ]; then
        printf 'PASS [%s]\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL [%s]: unexpected file exists: %s\n' "$label" "$path" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_dead() {
    local label="$1" pid="$2"
    if ! kill -0 "$pid" 2>/dev/null; then
        printf 'PASS [%s] (pid %s dead)\n' "$label" "$pid"
        PASS=$((PASS + 1))
    else
        printf 'FAIL [%s]: pid %s still alive\n' "$label" "$pid" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_alive() {
    local label="$1" pid="$2"
    if kill -0 "$pid" 2>/dev/null; then
        printf 'PASS [%s] (pid %s alive)\n' "$label" "$pid"
        PASS=$((PASS + 1))
    else
        printf 'FAIL [%s]: pid %s unexpectedly dead\n' "$label" "$pid" >&2
        FAIL=$((FAIL + 1))
    fi
}

make_sandbox() {
    local name="$1"
    local sb="$TMP_ROOT/$name"
    mkdir -p "$sb/home/.steam" "$sb/home/.local/share/Steam" \
             "$sb/home/.local/share/SLSsteam/path" \
             "$sb/home/.local/share/CloudRedirect" \
             "$sb/moon64"
    printf '%s' "$sb"
}

HOLDER_PID=""
spawn_mmap_holder() {
    local target_file="$1" hold_secs="$2" ready_file="$3"
    python3 - "$target_file" "$hold_secs" "$ready_file" </dev/null >/dev/null 2>&1 <<'PY' &
import mmap, os, sys, time
path, secs, ready = sys.argv[1], float(sys.argv[2]), sys.argv[3]
with open(path, "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    with open(ready, "w", encoding="utf-8") as rf:
        rf.write(str(os.getpid()))
    time.sleep(secs)
    mm.close()
PY
    HOLDER_PID=$!
    PIDS_TO_KILL+=("$HOLDER_PID")
    local tries=0
    while [ ! -s "$ready_file" ] && [ "$tries" -lt 40 ]; do
        sleep 0.05
        tries=$((tries + 1))
    done
}

# --- (a) Not running -> succeeds immediately, nothing invoked ---------------
sb="$(make_sandbox a-not-running)"
cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$sb/steam-sh-called"
exit 0
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
assert_rc "a1: not running exits 0" 0 "$rc" "$out"
assert_contains "a1: reports not running" "Steam is not running" "$out"
assert_not_exists "a1: steam.sh not invoked" "$sb/steam-sh-called"

# Stale pidfile -> also treated as not running, nothing invoked
printf '999999\n' > "$sb/home/.steam/steam.pid"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
assert_rc "a2: stale pidfile exits 0" 0 "$rc" "$out"
assert_not_exists "a2: steam.sh not invoked on stale pid" "$sb/steam-sh-called"

# --- (b) Fake steam.sh -shutdown kills pid -> graceful path ----------------
sb="$(make_sandbox b-graceful)"
sleep 300 &
client_pid=$!
PIDS_TO_KILL+=("$client_pid")
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"

cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
printf 'PWD=%s ARGS=%s FORCE=%s\n' "\$PWD" "\$*" "\${STEAM_FORCE_CLIENT-<UNSET>}" > "$sb/steam-sh-log"
if [ "\${1:-}" = "-shutdown" ]; then
    pid="\$(cat "$sb/home/.steam/steam.pid")"
    kill -TERM "\$pid" 2>/dev/null || true
    exit 0
fi
exit 1
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
    STEAM_FORCE_CLIENT="ubuntu12_32" \
    SLSM_STOP_STEAM_TIMEOUT=2 SLSM_STOP_STEAM_KILL_TIMEOUT=1 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
wait "$client_pid" 2>/dev/null || true
assert_rc "b: graceful shutdown exits 0" 0 "$rc" "$out"
assert_contains "b: reports graceful stop" "Steam stopped gracefully" "$out"
assert_dead "b: fake client killed" "$client_pid"
sh_log="$(cat "$sb/steam-sh-log" 2>/dev/null || true)"
assert_contains "b: steam.sh invoked from Steam root with -shutdown and unset STEAM_FORCE_CLIENT" \
    "PWD=$sb/home/.local/share/Steam ARGS=-shutdown FORCE=<UNSET>" "$sh_log"

# --- (c) Fake steam.sh does nothing -> SIGTERM fallback succeeds -----------
sb="$(make_sandbox c-sigterm)"
sleep 300 &
client_pid=$!
PIDS_TO_KILL+=("$client_pid")
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"

cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$sb/steam-sh-called"
exit 0
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
    SLSM_STOP_STEAM_TIMEOUT=0.3 SLSM_STOP_STEAM_KILL_TIMEOUT=2 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
wait "$client_pid" 2>/dev/null || true
assert_rc "c: sigterm fallback exits 0" 0 "$rc" "$out"
assert_contains "c: reports SIGTERM stop" "Steam stopped (SIGTERM)" "$out"
assert_dead "c: fake client killed by SIGTERM" "$client_pid"

# --- (d) Process ignoring SIGTERM -> fails naming pid, no SIGKILL ----------
sb="$(make_sandbox d-ignore-term)"
bash -c 'trap "" TERM; exec sleep 300' &
stubborn_pid=$!
PIDS_TO_KILL+=("$stubborn_pid")
printf '%s\n' "$stubborn_pid" > "$sb/home/.steam/steam.pid"

cat > "$sb/home/.local/share/Steam/steam.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
    SLSM_STOP_STEAM_TIMEOUT=0.2 SLSM_STOP_STEAM_KILL_TIMEOUT=0.3 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
assert_rc "d: stubborn pid fails non-zero" 1 "$rc" "$out"
assert_contains "d: failure names stubborn pid" "pid $stubborn_pid" "$out"
assert_alive "d: no SIGKILL sent to stubborn pid" "$stubborn_pid"
kill -KILL "$stubborn_pid" 2>/dev/null || true
wait "$stubborn_pid" 2>/dev/null || true

# --- (e) Active SteamAppId process -> refuses, SLSM_STOP_STEAM=force proceeds
sb="$(make_sandbox e-game-guard)"
sleep 300 &
client_pid=$!
PIDS_TO_KILL+=("$client_pid")
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"

env SteamAppId=526870 sleep 300 &
game_pid=$!
PIDS_TO_KILL+=("$game_pid")

cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$sb/steam-sh-called"
pid="\$(cat "$sb/home/.steam/steam.pid")"
kill -TERM "\$pid" 2>/dev/null || true
exit 0
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
    SLSM_STOP_STEAM_TIMEOUT=1 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
assert_rc "e1: active game refuses non-zero" 1 "$rc" "$out"
assert_contains "e1: names active appid" "526870" "$out"
assert_contains "e1: prints SLSM_STOP_STEAM=force override" "SLSM_STOP_STEAM=force" "$out"
assert_alive "e1: client not touched when game guard refuses" "$client_pid"
assert_not_exists "e1: steam.sh not invoked when game guard refuses" "$sb/steam-sh-called"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
    SLSM_STOP_STEAM=force SLSM_STOP_STEAM_TIMEOUT=2 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
wait "$client_pid" 2>/dev/null || true
kill -KILL "$game_pid" 2>/dev/null || true
wait "$game_pid" 2>/dev/null || true
assert_rc "e2: SLSM_STOP_STEAM=force proceeds and exits 0" 0 "$rc" "$out"
assert_dead "e2: client stopped under force" "$client_pid"

# --- (f) Mapped-file guard (deterministic python mmap) ---------------------
sb="$(make_sandbox f-maps-guard)"
printf 'dummy shared object bytes\n' > "$sb/home/.local/share/SLSsteam/SLSsteam.so"
printf 'dummy backup bytes\n' > "$sb/home/.local/share/SLSsteam/SLSsteam.so.32"

# f1: Holder remains past MAPS_TIMEOUT -> refuses with pid -> file
spawn_mmap_holder "$sb/home/.local/share/SLSsteam/SLSsteam.so" 10 "$sb/f1.ready"
holder_pid="$HOLDER_PID"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=0.3 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
kill -KILL "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
assert_rc "f1: lingering mapped holder fails non-zero" 1 "$rc" "$out"
assert_contains "f1: prints pid -> file" "$holder_pid -> $sb/home/.local/share/SLSsteam/SLSsteam.so" "$out"

# f2: Holder exits within MAPS_TIMEOUT -> waits and succeeds
spawn_mmap_holder "$sb/home/.local/share/SLSsteam/SLSsteam.so" 0.4 "$sb/f2.ready"
holder_pid="$HOLDER_PID"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=3 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
wait "$holder_pid" 2>/dev/null || true
assert_rc "f2: released mapped holder exits 0" 0 "$rc" "$out"

# f3: Sibling SLSsteam.so.32 does NOT false-match SLSsteam.so
spawn_mmap_holder "$sb/home/.local/share/SLSsteam/SLSsteam.so.32" 10 "$sb/f3.ready"
holder_pid="$HOLDER_PID"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=0.3 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
kill -KILL "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
assert_rc "f3: SLSsteam.so.32 does not false-match SLSsteam.so" 0 "$rc" "$out"

# --- (g) End-to-end install.sh wiring stops running Steam before gate ------
sb="$(make_sandbox g-install-wiring)"
sleep 300 &
client_pid=$!
PIDS_TO_KILL+=("$client_pid")
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"

cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-shutdown" ]; then
    pid="\$(cat "$sb/home/.steam/steam.pid")"
    kill -TERM "\$pid" 2>/dev/null || true
    exit 0
fi
exit 1
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

mkdir -p "$sb/src/res"
printf 'all:\n\t@echo SHOULD_NOT_RUN; exit 99\n' > "$sb/src/Makefile"
printf 'arch=x86_64\nrequired=38\nresolved=21\npending=17\nrunipcframe_tail=ready\n' > "$sb/src/res/pattern-status.txt"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLS64_SRC="$sb/src" \
    SLSM_STOP_STEAM_TIMEOUT=2 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/install.sh" 2>&1
)"
rc=$?
wait "$client_pid" 2>/dev/null || true
assert_rc "g: install.sh runs stop-steam then fails at pattern gate" 1 "$rc" "$out"
assert_contains "g: install.sh stopped Steam gracefully" "Steam stopped gracefully" "$out"
assert_contains "g: install.sh proceeded to pattern gate" "refusing to stage an incomplete build" "$out"
assert_dead "g: fake Steam stopped by install.sh" "$client_pid"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
