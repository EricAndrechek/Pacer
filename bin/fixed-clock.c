// Pins a process's wall clock for the README screenshot run (#154).
//
// Seeded data and every clock label in the screenshots are built from "now",
// so a run at a different hour drew different pictures and every PR's
// screenshot commit was mostly noise. The app reads the clock in a few hundred
// places (views, formatters, the forecast engine); threading an injectable
// clock through all of them would be the widest change in the codebase and
// one missed call would bring the noise back. This pins it from outside
// instead, for the screenshot process only.
//
// Inserted with DYLD_INSERT_LIBRARIES by bin/dev-screenshots.sh, which works
// because `make verify` builds without signing, so without hardened runtime.
// Never linked into anything that ships.
//
// PACER_FIXED_NOW (Unix seconds) is where the clock starts; from there it
// advances in real time, so timers, sleeps and timeouts behave normally. The
// time zone is pinned separately, with TZ.
//
// Build: clang -dynamiclib -O2 -framework CoreFoundation -o libfixedclock.dylib fixed-clock.c

#include <time.h>
#include <sys/time.h>
#include <stdlib.h>
#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

static double offset_s;   // pinned minus real, fixed at first use
static int ready;

// Calls from this image are not interposed, so these reach the real clock.
static double real_unix(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double pinned_unix(void) {
    if (!ready) {
        const char *v = getenv("PACER_FIXED_NOW");
        offset_s = v ? atof(v) - real_unix() : 0;
        ready = 1;
    }
    return real_unix() + offset_s;
}

static int pinned_gettimeofday(struct timeval *tv, void *tz) {
    int r = gettimeofday(tv, tz);
    if (tv) {
        double f = pinned_unix();
        tv->tv_sec = (time_t)f;
        tv->tv_usec = (suseconds_t)((f - (double)(time_t)f) * 1e6);
    }
    return r;
}

static int pinned_clock_gettime(clockid_t id, struct timespec *ts) {
    int r = clock_gettime(id, ts);
    // Only the wall clock. Monotonic clocks drive timers and must stay real.
    if (r == 0 && ts && id == CLOCK_REALTIME) {
        double f = pinned_unix();
        ts->tv_sec = (time_t)f;
        ts->tv_nsec = (long)((f - (double)(time_t)f) * 1e9);
    }
    return r;
}

static uint64_t pinned_clock_gettime_nsec_np(clockid_t id) {
    if (id == CLOCK_REALTIME) return (uint64_t)(pinned_unix() * 1e9);
    return clock_gettime_nsec_np(id);
}

static time_t pinned_time(time_t *t) {
    time_t f = (time_t)pinned_unix();
    if (t) *t = f;
    return f;
}

static CFAbsoluteTime pinned_CFAbsoluteTimeGetCurrent(void) {
    return pinned_unix() - kCFAbsoluteTimeIntervalSince1970;
}

#define INTERPOSE(replacement, original) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    interpose_##original __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)&replacement, (const void *)&original };

INTERPOSE(pinned_gettimeofday, gettimeofday)
INTERPOSE(pinned_clock_gettime, clock_gettime)
INTERPOSE(pinned_clock_gettime_nsec_np, clock_gettime_nsec_np)
INTERPOSE(pinned_time, time)
INTERPOSE(pinned_CFAbsoluteTimeGetCurrent, CFAbsoluteTimeGetCurrent)
