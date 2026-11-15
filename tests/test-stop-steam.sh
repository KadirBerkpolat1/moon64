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
    # Restore permissions inside TMP_ROOT before rm -rf (e.g. chmod 000 fake maps).
    chmod -R u+rwx "$TMP_ROOT" 2>/dev/null || true
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

assert_not_contains() {
    local label="$1" substr="$2" text="$3"
    case "$text" in
        *"$substr"*)
            printf 'FAIL [%s]: unexpected %q in:\n%s\n' "$label" "$substr" "$text" >&2
            FAIL=$((FAIL + 1))
            ;;
        *)
            printf 'PASS [%s]\n' "$label"
            PASS=$((PASS + 1))
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

assert_lt() {
    local label="$1" actual="$2" limit="$3"
    if [ "$actual" -lt "$limit" ]; then
        printf 'PASS [%s] (%sms < %sms)\n' "$label" "$actual" "$limit"
        PASS=$((PASS + 1))
    else
        printf 'FAIL [%s]: %s >= %s\n' "$label" "$actual" "$limit" >&2
        FAIL=$((FAIL + 1))
    fi
}

make_sandbox() {
    local name="$1"
    local sb="$TMP_ROOT/$name"
    mkdir -p "$sb/home/.steam" "$sb/home/.local/share/Steam/steamrt64" \
             "$sb/home/.local/share/SLSsteam/path" \
             "$sb/home/.local/share/CloudRedirect" \
             "$sb/moon64" "$sb/proc" "$sb/tmp"
    printf '%s' "$sb"
}

FAKE_STEAM_PID=""
spawn_fake_steam() {
    local sb="$1" ignore_term="${2:-0}"
    local steam_bin="$sb/home/.local/share/Steam/steamrt64/steam"
    cp "$(command -v sleep)" "$steam_bin"
    chmod +x "$steam_bin"
    if [ "$ignore_term" = 1 ]; then
        bash -c 'trap "" TERM; exec "$1" 300' _ "$steam_bin" &
    else
        "$steam_bin" 300 &
    fi
    FAKE_STEAM_PID=$!
    PIDS_TO_KILL+=("$FAKE_STEAM_PID")
    ln -s "/proc/$FAKE_STEAM_PID" "$sb/proc/$FAKE_STEAM_PID"
}

HOLDER_PID=""
spawn_mmap_holder() {
    local target_file="$1" hold_secs="$2" ready_file="$3"
    local py_bin
    py_bin="$(command -v python3)"
    "$py_bin" - "$target_file" "$hold_secs" "$ready_file" </dev/null >/dev/null 2>&1 <<'PY' &
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

# Build a PATH directory containing required utilities but NO python3.
NOPY_BIN="$TMP_ROOT/nopy-bin"
mkdir -p "$NOPY_BIN"
for cmd in awk bash cat date env kill mkdir readlink rm sed sleep timeout tr; do
    if p="$(command -v "$cmd" 2>/dev/null)"; then
        ln -sf "$p" "$NOPY_BIN/$cmd"
    fi
done

# --- (a) Not running / stale / non-Steam PID -> succeeds, nothing invoked ---
sb="$(make_sandbox a-not-running)"
cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$sb/steam-sh-called"
exit 0
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_TIMEOUT=1 SLSM_STOP_STEAM_KILL_TIMEOUT=1 SLSM_STOP_STEAM_MAPS_TIMEOUT=1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
assert_rc "a1: not running exits 0" 0 "$rc" "$out"
assert_contains "a1: reports not running" "Steam is not running" "$out"
assert_not_exists "a1: steam.sh not invoked" "$sb/steam-sh-called"

# a2: Stale pidfile from a reaped child -> treated as not running
true &
stale_pid=$!
wait "$stale_pid" 2>/dev/null || true
printf '%s\n' "$stale_pid" > "$sb/home/.steam/steam.pid"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_TIMEOUT=1 SLSM_STOP_STEAM_KILL_TIMEOUT=1 SLSM_STOP_STEAM_MAPS_TIMEOUT=1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
assert_rc "a2: stale pidfile exits 0" 0 "$rc" "$out"
assert_contains "a2: reports not running" "Steam is not running" "$out"
assert_not_exists "a2: steam.sh not invoked on stale pid" "$sb/steam-sh-called"

# a3 (D2): Live non-Steam process (plain sleep) in steam.pid -> ignored, not killed
sleep 300 &
other_pid=$!
PIDS_TO_KILL+=("$other_pid")
ln -s "/proc/$other_pid" "$sb/proc/$other_pid"
printf '%s\n' "$other_pid" > "$sb/home/.steam/steam.pid"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_TIMEOUT=1 SLSM_STOP_STEAM_KILL_TIMEOUT=1 SLSM_STOP_STEAM_MAPS_TIMEOUT=1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
assert_rc "a3: non-Steam pid exits 0" 0 "$rc" "$out"
assert_contains "a3: reports not running on non-Steam pid" "Steam is not running" "$out"
assert_not_exists "a3: steam.sh not invoked on non-Steam pid" "$sb/steam-sh-called"
assert_alive "a3: non-Steam pid untouched" "$other_pid"
kill -KILL "$other_pid" 2>/dev/null || true
wait "$other_pid" 2>/dev/null || true

# --- (b) Fake steam.sh -shutdown kills steam client -> graceful path --------
sb="$(make_sandbox b-graceful)"
spawn_fake_steam "$sb" 0
client_pid="$FAKE_STEAM_PID"
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
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    STEAM_FORCE_CLIENT="ubuntu12_32" \
    SLSM_STOP_STEAM_TIMEOUT=2 SLSM_STOP_STEAM_KILL_TIMEOUT=1 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
wait "$client_pid" 2>/dev/null || true
assert_rc "b1: graceful shutdown exits 0" 0 "$rc" "$out"
assert_contains "b1: reports graceful stop" "Steam stopped gracefully" "$out"
assert_dead "b1: fake client killed" "$client_pid"
sh_log="$(cat "$sb/steam-sh-log" 2>/dev/null || true)"
assert_contains "b1: steam.sh invoked from Steam root with -shutdown and unset STEAM_FORCE_CLIENT" \
    "PWD=$sb/home/.local/share/Steam ARGS=-shutdown FORCE=<UNSET>" "$sh_log"

# b2 (D3): LC_ALL=tr_TR.UTF-8 (comma decimal EPOCHREALTIME) takes graceful path
sb="$(make_sandbox b2-tr-locale)"
spawn_fake_steam "$sb" 0
client_pid="$FAKE_STEAM_PID"
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"
cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = "-shutdown" ]; then
    sleep 0.2
    pid="\$(cat "$sb/home/.steam/steam.pid")"
    kill -TERM "\$pid" 2>/dev/null || true
    exit 0
fi
exit 1
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    LC_ALL=tr_TR.UTF-8 HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_TIMEOUT=2 SLSM_STOP_STEAM_KILL_TIMEOUT=1 SLSM_STOP_STEAM_POLL=0.05 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
wait "$client_pid" 2>/dev/null || true
assert_rc "b2: tr_TR.UTF-8 graceful shutdown exits 0" 0 "$rc" "$out"
assert_contains "b2: tr_TR.UTF-8 takes graceful path" "Steam stopped gracefully" "$out"
assert_not_contains "b2: tr_TR.UTF-8 does not fall through to SIGTERM" "SIGTERM" "$out"
assert_dead "b2: fake client killed under tr_TR.UTF-8" "$client_pid"

# --- (c) SIGTERM fallback (silent steam.sh & hanging steam.sh) --------------
sb="$(make_sandbox c-sigterm)"
spawn_fake_steam "$sb" 0
client_pid="$FAKE_STEAM_PID"
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"

cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$sb/steam-sh-called"
exit 0
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_TIMEOUT=0.3 SLSM_STOP_STEAM_KILL_TIMEOUT=2 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
wait "$client_pid" 2>/dev/null || true
assert_rc "c1: sigterm fallback exits 0" 0 "$rc" "$out"
assert_contains "c1: reports SIGTERM stop" "Steam stopped (SIGTERM)" "$out"
assert_dead "c1: fake client killed by SIGTERM" "$client_pid"

# c2 (D1): Hanging steam.sh never returns -> bounded by timeout, reaches SIGTERM within budget
sb="$(make_sandbox c2-hang-steam-sh)"
spawn_fake_steam "$sb" 0
client_pid="$FAKE_STEAM_PID"
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"
cat > "$sb/home/.local/share/Steam/steam.sh" <<'SH'
#!/usr/bin/env bash
sleep 300
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

t0="$(date +%s%3N)"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_TIMEOUT=0.3 SLSM_STOP_STEAM_KILL_TIMEOUT=2 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
t1="$(date +%s%3N)"
wait "$client_pid" 2>/dev/null || true
assert_rc "c2: hanging steam.sh falls back to SIGTERM and exits 0" 0 "$rc" "$out"
assert_contains "c2: reports SIGTERM stop after hanging steam.sh" "Steam stopped (SIGTERM)" "$out"
assert_dead "c2: fake client killed after hanging steam.sh" "$client_pid"
assert_lt "c2: completed within timeout budget" "$((t1 - t0))" 3000

# --- (d) Process ignoring SIGTERM -> fails naming pid, no SIGKILL ----------
sb="$(make_sandbox d-ignore-term)"
spawn_fake_steam "$sb" 1
stubborn_pid="$FAKE_STEAM_PID"
printf '%s\n' "$stubborn_pid" > "$sb/home/.steam/steam.pid"

cat > "$sb/home/.local/share/Steam/steam.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
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
spawn_fake_steam "$sb" 0
client_pid="$FAKE_STEAM_PID"
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"

env SteamAppId=526870 sleep 300 &
game_pid=$!
PIDS_TO_KILL+=("$game_pid")
ln -s "/proc/$game_pid" "$sb/proc/$game_pid"

cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$sb/steam-sh-called"
pid="\$(cat "$sb/home/.steam/steam.pid")"
kill -TERM "\$pid" 2>/dev/null || true
exit 0
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
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
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
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
ln -s "/proc/$holder_pid" "$sb/proc/$holder_pid"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=0.3 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
kill -KILL "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -f "$sb/proc/$holder_pid"
assert_rc "f1: lingering mapped holder fails non-zero" 1 "$rc" "$out"
assert_contains "f1: prints pid -> file" "$holder_pid -> $sb/home/.local/share/SLSsteam/SLSsteam.so" "$out"

# f2: Holder exits within MAPS_TIMEOUT -> waits and succeeds
spawn_mmap_holder "$sb/home/.local/share/SLSsteam/SLSsteam.so" 0.4 "$sb/f2.ready"
holder_pid="$HOLDER_PID"
ln -s "/proc/$holder_pid" "$sb/proc/$holder_pid"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=3 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
wait "$holder_pid" 2>/dev/null || true
rm -f "$sb/proc/$holder_pid"
assert_rc "f2: released mapped holder exits 0" 0 "$rc" "$out"

# f3: Sibling SLSsteam.so.32 does NOT false-match SLSsteam.so
spawn_mmap_holder "$sb/home/.local/share/SLSsteam/SLSsteam.so.32" 10 "$sb/f3.ready"
holder_pid="$HOLDER_PID"
ln -s "/proc/$holder_pid" "$sb/proc/$holder_pid"
out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=0.3 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
kill -KILL "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -f "$sb/proc/$holder_pid"
assert_rc "f3: SLSsteam.so.32 does not false-match SLSsteam.so" 0 "$rc" "$out"

# --- (d4) Broken python3 stub must fail closed in BOTH guards ----------------
sb="$(make_sandbox d4-broken-python)"
mkdir -p "$sb/badpy-exit1" "$sb/badpy-empty"
printf '#!/usr/bin/env bash\nexit 1\n' > "$sb/badpy-exit1/python3"
printf '#!/usr/bin/env bash\nexit 0\n' > "$sb/badpy-empty/python3"
chmod +x "$sb/badpy-exit1/python3" "$sb/badpy-empty/python3"

# d4a: python3 exits 1 during game guard -> refuses, client untouched
spawn_fake_steam "$sb" 0
client_pid="$FAKE_STEAM_PID"
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"
cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$sb/steam-sh-called"
exit 0
SH
chmod +x "$sb/home/.local/share/Steam/steam.sh"

out="$(
    PATH="$sb/badpy-exit1:$PATH" HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
assert_rc "d4a: broken python3 (exit 1) refuses in game guard" 1 "$rc" "$out"
assert_alive "d4a: client alive when game guard fails" "$client_pid"
assert_not_exists "d4a: steam.sh not invoked when game guard fails" "$sb/steam-sh-called"

# d4c1: python3 exits 0 with empty stdout during game guard -> refuses
out="$(
    PATH="$sb/badpy-empty:$PATH" HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
kill -KILL "$client_pid" 2>/dev/null || true
wait "$client_pid" 2>/dev/null || true
rm -f "$sb/home/.steam/steam.pid" "$sb/proc/$client_pid"
assert_rc "d4c1: empty python3 (exit 0) refuses in game guard" 1 "$rc" "$out"

# d4b + d4c2: python3 exits 1 or empty stdout during mapped-file guard -> refuses
printf 'dummy shared object bytes\n' > "$sb/home/.local/share/SLSsteam/SLSsteam.so"
spawn_mmap_holder "$sb/home/.local/share/SLSsteam/SLSsteam.so" 10 "$sb/d4b.ready"
holder_pid="$HOLDER_PID"
ln -s "/proc/$holder_pid" "$sb/proc/$holder_pid"

out="$(
    PATH="$sb/badpy-exit1:$PATH" HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=0.2 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
assert_rc "d4b: broken python3 (exit 1) refuses in maps guard" 1 "$rc" "$out"

out="$(
    PATH="$sb/badpy-empty:$PATH" HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=0.2 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
kill -KILL "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -f "$sb/proc/$holder_pid"
assert_rc "d4c2: empty python3 (exit 0) refuses in maps guard" 1 "$rc" "$out"

# --- (nopy) No-python3 bash/awk fallback (ELEVATED) --------------------------
sb="$(make_sandbox nopy-fallback)"
spawn_fake_steam "$sb" 0
client_pid="$FAKE_STEAM_PID"
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"
env SteamAppId=526870 sleep 300 &
game_pid=$!
PIDS_TO_KILL+=("$game_pid")
ln -s "/proc/$game_pid" "$sb/proc/$game_pid"

out="$(
    PATH="$NOPY_BIN" HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
kill -KILL "$client_pid" "$game_pid" 2>/dev/null || true
wait "$client_pid" "$game_pid" 2>/dev/null || true
rm -f "$sb/home/.steam/steam.pid" "$sb/proc/$client_pid" "$sb/proc/$game_pid"
assert_rc "nopy-e: bash game guard detects SteamAppId without python3" 1 "$rc" "$out"
assert_contains "nopy-e: names active appid without python3" "526870" "$out"

# nopy-f1: awk maps scan detects holder + unreadable maps entry
printf 'dummy shared object bytes\n' > "$sb/home/.local/share/SLSsteam/SLSsteam.so"
printf 'dummy backup bytes\n' > "$sb/home/.local/share/SLSsteam/SLSsteam.so.32"
mkdir -p "$sb/proc/999998"
: > "$sb/proc/999998/maps"
chmod 000 "$sb/proc/999998/maps"

spawn_mmap_holder "$sb/home/.local/share/SLSsteam/SLSsteam.so" 10 "$sb/nopy-f1.ready"
holder_pid="$HOLDER_PID"
ln -s "/proc/$holder_pid" "$sb/proc/$holder_pid"

out="$(
    PATH="$NOPY_BIN" HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=0.3 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
kill -KILL "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -f "$sb/proc/$holder_pid"
chmod 644 "$sb/proc/999998/maps" 2>/dev/null || true
rm -rf "$sb/proc/999998"
assert_rc "nopy-f1: awk fallback detects lingering holder" 1 "$rc" "$out"
assert_contains "nopy-f1: prints pid -> file" "$holder_pid -> $sb/home/.local/share/SLSsteam/SLSsteam.so" "$out"
assert_contains "nopy-f1: counts unreadable maps" "skipped 1 unreadable /proc/<pid>/maps entries" "$out"

# nopy-f2: awk fallback does not false-match SLSsteam.so.32
spawn_mmap_holder "$sb/home/.local/share/SLSsteam/SLSsteam.so.32" 10 "$sb/nopy-f2.ready"
holder_pid="$HOLDER_PID"
ln -s "/proc/$holder_pid" "$sb/proc/$holder_pid"
out="$(
    PATH="$NOPY_BIN" HOME="$sb/home" MOON64_DIR="$sb/moon64" SLSM_PROC_ROOT="$sb/proc" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=0.3 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
kill -KILL "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -f "$sb/proc/$holder_pid"
assert_rc "nopy-f2: awk fallback ignores SLSsteam.so.32" 0 "$rc" "$out"

# nopy-f3: Real /proc scan without python3 is fast and emits zero Permission denied
t0="$(date +%s%3N)"
out="$(
    PATH="$NOPY_BIN" HOME="$sb/home" MOON64_DIR="$sb/moon64" \
    SLSM_STOP_STEAM_MAPS_TIMEOUT=1 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/bin/moon64" stop-steam 2>&1
)"
rc=$?
t1="$(date +%s%3N)"
assert_rc "nopy-f3: real /proc scan without python3 succeeds" 0 "$rc" "$out"
assert_not_contains "nopy-f3: zero Permission denied on stderr" "Permission denied" "$out"
assert_lt "nopy-f3: real /proc scan completes quickly" "$((t1 - t0))" 5000

# --- (g) install.sh runs stop-steam AFTER gate+build, before live writes ----
# g1 (D5): Failed pattern gate must NOT stop running Steam
sb="$(make_sandbox g1-gate-before-stop)"
spawn_fake_steam "$sb" 0
client_pid="$FAKE_STEAM_PID"
printf '%s\n' "$client_pid" > "$sb/home/.steam/steam.pid"

cat > "$sb/home/.local/share/Steam/steam.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$sb/steam-sh-called"
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
    SLSM_PROC_ROOT="$sb/proc" TMPDIR="$sb/tmp" \
    SLSM_STOP_STEAM_TIMEOUT=2 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/install.sh" 2>&1
)"
rc=$?
assert_rc "g1: install.sh refuses at pattern gate" 1 "$rc" "$out"
assert_contains "g1: install.sh prints gate failure" "refusing to stage an incomplete build" "$out"
assert_not_contains "g1: install.sh did not stop Steam before gate" "Steam stopped" "$out"
assert_not_exists "g1: steam.sh not invoked on gate failure" "$sb/steam-sh-called"
assert_alive "g1: fake Steam still running after gate failure" "$client_pid"
kill -KILL "$client_pid" 2>/dev/null || true
wait "$client_pid" 2>/dev/null || true

# g2 (D5): Passing gate + build -> stop-steam runs right before live writes
sb="$(make_sandbox g2-stop-after-build)"
spawn_fake_steam "$sb" 0
client_pid="$FAKE_STEAM_PID"
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

mkdir -p "$sb/src/res" "$sb/src/bin"
cat > "$sb/src/Makefile" <<'MK'
all:
	mkdir -p bin
	printf '#include <stdio.h>\nvoid sls_dummy(void) { puts("ok"); }\n' | gcc -shared -fPIC -x c - -o bin/SLSsteam.so
MK
printf 'arch=x86_64\nrequired=38\nresolved=38\npending=0\nrunipcframe_tail=ready\n' > "$sb/src/res/pattern-status.txt"

out="$(
    HOME="$sb/home" MOON64_DIR="$sb/moon64" SLS64_SRC="$sb/src" \
    SLSM_PROC_ROOT="$sb/proc" TMPDIR="$sb/tmp" \
    SLSM_STOP_STEAM_TIMEOUT=2 SLSM_STOP_STEAM_POLL=0.1 \
        bash "$REPO_ROOT/install.sh" 2>&1
)"
rc=$?
wait "$client_pid" 2>/dev/null || true
assert_rc "g2: install.sh passes gate+build and stops Steam before staging" 0 "$rc" "$out"
assert_contains "g2: install.sh stopped Steam gracefully" "Steam stopped gracefully" "$out"
assert_contains "g2: install.sh completed staging" "staging complete; nothing has been activated" "$out"
assert_dead "g2: fake Steam stopped by install.sh" "$client_pid"

printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
