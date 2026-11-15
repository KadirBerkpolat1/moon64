// netsock64 — SteamNetworkingSockets cert-store patch for the 64-bit Steam client
//
// Why: a Windows online fix swaps the AppID at the client layer (OnlineFix.ini
// FakeAppId). SLSsteam's FakeAppIds reproduces that swap on Linux, but
// steamclient.so additionally validates the SDR networking certificate against
// the AppID it believes it is running as. When the lobby is hosted/joined under
// Spacewar (480) while the ticket says otherwise, the predicate that prints
// "Cert is not authorized for appid %u, only %u" returns false and P2P dies in
// about a second with PendingConnectionFailure.
//
// Upstream steamnetsock-patch (yesyes0649) fixes the same predicate, but its
// 14-byte pattern was taken from linux64/steamclient.so. The client that the
// modern 64-bit Steam actually runs is steamrt64/steamclient.so, built with a
// different register allocation, so that pattern does not match it.
//
// This shim carries one exact anchor per known build and patches the function
// entry to `mov eax,1; ret` (same outcome as upstream: predicate returns true).
// Both anchors were verified unique over the whole .text of the shipped
// libraries (steamrt64 2026-10-22, linux64 2026-10-22). A future client that
// reallocates registers matches neither anchor, in which case the shim logs
// "no anchor" and leaves memory untouched — fail closed, never blind-patch.
//
// LD_AUDIT cannot be used to change game behaviour; this only runs inside the
// Steam client process, which is the process that performs the P2P handshake.

#define _GNU_SOURCE
#include <link.h>
#include <stdio.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <time.h>

#define PATCH_LEN 6

// Absolute log path.  A relative name would land in whatever cwd the launcher
// happened to have (Steam's cwd, or a desktop entry's), which is why the
// documented path and the real file disagreed.  $HOME/.local/share/moon64 is
// the directory the installer and the switcher already own.
static char g_log_path[512];

static void log_path_init(void)
{
    const char *home = getenv("HOME");
    if (home && *home)
        snprintf(g_log_path, sizeof g_log_path,
                 "%s/.local/share/moon64/moon64-netsock.log", home);
    else
        snprintf(g_log_path, sizeof g_log_path, "/tmp/moon64-netsock.log");
}

// Function entry, linux64/steamclient.so lineage (2026-10-22).
static const uint8_t ANCHOR_LINUX64[] = {
    0x41, 0x54, 0x41, 0x89, 0xD4, 0x55, 0x48, 0x89, 0xCD, 0x53, 0x44,
    0x8B, 0x47, 0x28, 0x48, 0x89, 0xF3, 0x45, 0x85, 0xC0, 0x0F, 0x85,
};

// Function entry, steamrt64/steamclient.so lineage (2026-10-22): same function,
// `mov %esi,%r12` instead of `mov %edx,%r12d` and a 2-byte `mov %edx,%ebx`.
static const uint8_t ANCHOR_STEAMRT64[] = {
    0x41, 0x54, 0x49, 0x89, 0xF4, 0x55, 0x48, 0x89, 0xCD, 0x53, 0x44,
    0x8B, 0x47, 0x28, 0x89, 0xD3, 0x45, 0x85, 0xC0, 0x0F, 0x85,
};

// mov eax,1 ; ret
static const uint8_t PATCH[] = { 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 };

static FILE *g_log;

static void logf_(const char *fmt, ...)
{
    if (!g_log) {
        if (!g_log_path[0]) log_path_init();
        g_log = fopen(g_log_path, "a");
    }
    if (!g_log) return;
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    char ts[32];
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tm);
    fprintf(g_log, "[%s] ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(g_log, fmt, ap);
    va_end(ap);
    fputc('\n', g_log);
    fflush(g_log);
}

static const char *base_name(const char *p)
{
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

// Count non-overlapping occurrences of `needle` in [start,start+len).
static size_t count_matches(const uint8_t *start, size_t len,
                            const uint8_t *needle, size_t nlen,
                            uint8_t **first)
{
    size_t hits = 0;
    if (len < nlen) return 0;
    for (size_t i = 0; i + nlen <= len; i++) {
        if (memcmp(start + i, needle, nlen) == 0) {
            if (hits == 0 && first) *first = (uint8_t *)(start + i);
            hits++;
        }
    }
    return hits;
}


// executable_ranges(lib_suffix) -> first executable mapping of the library.
// /proc/self/maps is authoritative at la_objopen time: the object is open but
// not yet in the link map, so dl_iterate_phdr would not see it (and the mapped
// address, unlike a file offset, is valid for this build either way).
static int find_exec_range(const char *lib_suffix, uintptr_t *out_lo, uintptr_t *out_hi)
{
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return 0;
    char line[512];
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        unsigned long lo = 0, hi = 0;
        char perms[8] = {0};
        if (sscanf(line, "%lx-%lx %7s", &lo, &hi, perms) != 3) continue;
        if (perms[2] != 'x') continue;
        if (!strstr(line, lib_suffix)) continue;
        *out_lo = (uintptr_t)lo;
        *out_hi = (uintptr_t)hi;
        found = 1;
        break;
    }
    fclose(f);
    return found;
}

static void patch_one(const char *name)
{
    const char *suffix = strstr(name, "steamrt64") ? "steamrt64/steamclient.so" : "linux64/steamclient.so";
    uintptr_t lo = 0, hi = 0;
    if (!find_exec_range(suffix, &lo, &hi)) {
        logf_("%s: no executable mapping for %s, skipped", name, suffix);
        return;
    }

    size_t len = (size_t)(hi - lo);
    uint8_t *a = NULL, *b = NULL;
    size_t ha = count_matches((const uint8_t *)lo, len, ANCHOR_LINUX64, sizeof ANCHOR_LINUX64, &a);
    size_t hb = count_matches((const uint8_t *)lo, len, ANCHOR_STEAMRT64, sizeof ANCHOR_STEAMRT64, &b);

    logf_("%s: text %p-%p (%zu bytes) anchors steamrt64=%zu linux64=%zu",
          name, (void *)lo, (void *)hi, len, hb, ha);

    if (ha + hb == 0) {
        logf_("no anchor matched - client build not recognised, memory untouched");
        return;
    }
    if (ha + hb > 1) {
        logf_("ambiguous (%zu anchors) - refusing to patch", ha + hb);
        return;
    }

    uint8_t *target = ha ? a : b;
    long page = sysconf(_SC_PAGESIZE);
    uintptr_t start = (uintptr_t)target & ~(uintptr_t)(page - 1);
    uintptr_t end = ((uintptr_t)target + PATCH_LEN + (uintptr_t)page - 1) & ~(uintptr_t)(page - 1);

    if (mprotect((void *)start, (size_t)(end - start), PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        logf_("mprotect failed (%m) - memory untouched");
        return;
    }
    memcpy(target, PATCH, PATCH_LEN);
    if (mprotect((void *)start, (size_t)(end - start), PROT_READ | PROT_EXEC) != 0)
        logf_("warning: could not restore RX on %p (%m)", (void *)start);

    logf_("patched %s at %p (offset in mapping %#lx) -> mov eax,1; ret",
          suffix, (void *)target, (unsigned long)((uintptr_t)target - lo));
}

// The shim is inherited by every process the launcher spawns (steam.sh runs
// mkdir/ln/readlink before exec'ing the client).  Those helpers never open a
// steamclient.so, so they cannot patch anything -- but their la_version would
// still append an "audit loaded" line, turning the log into noise.  Gate the
// logging on the process actually being the Steam client, the same test
// SLSsteam uses (process name == "steam").
static int is_steam_process(void)
{
    char buf[64];
    ssize_t n = readlink("/proc/self/comm", buf, sizeof buf - 1);
    if (n <= 0) return 0;
    buf[n] = '\0';
    return strncmp(buf, "steam", 5) == 0;
}

unsigned int la_version(unsigned int version)
{
    if (is_steam_process())
        logf_("audit loaded, la_version %u", version);
    /* Answer with what the loader offered, capped at what we implement. Asking
     * for LAV_CURRENT unconditionally aborts the process on a loader that only
     * knows an older interface, instead of letting it ignore us. */
    return version == 0 ? LAV_CURRENT
                        : (version < LAV_CURRENT ? version : LAV_CURRENT);
}

unsigned int la_objopen(struct link_map *map, Lmid_t lmid, uintptr_t *cookie)
{
    (void)lmid;
    (void)cookie;
    const char *name = map->l_name;
    if (!name || !*name) return 0;
    if (strcmp(base_name(name), "steamclient.so") != 0) return 0;
    if (!strstr(name, "linux64") && !strstr(name, "steamrt64")) return 0;
    logf_("steamclient.so opened: %s", name);
    patch_one(name);
    return 0;
}
